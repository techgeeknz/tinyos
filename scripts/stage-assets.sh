#!/usr/bin/env sh
# stage-assets.sh — stage init/busybox and config overlays into staging
# Usage:
#   stage-assets.sh \
#     --stage-root        /abs/path/to/staging \
#     --init              ./rootfs/init.d \
#     --busybox           /abs/path/to/busybox \
#     [--readme-initramfs ./rootfs/README.initramfs] \
#     [--readme-payload   ./rootfs/README.payload] \
#     [--files-dir        ./config/files]         # expects subdirs: initramfs/ and payload/ \
#     [--tinyos-conf      ./config/tinyos.conf]   # written ONLY to initramfs/etc/tinyos.conf \
#     [--verbose]
#
# Notes:
#   - We create BusyBox init scaffolding first (/etc/inittab + /etc/init.d/rcS),
#     then apply overlays so they can intentionally override those files.
#   - We still force-install init+busybox LAST so overlays cannot shadow core binaries.
#   - Exactly one init is provided: canonical /init (executable) with /sbin/init → /init symlink.
#   - rcS uses 'busybox mountpoint -q' to avoid over-mounting /proc, /sys, /dev.
#   - We do NOT fall back to tmpfs for /dev; kernel is expected to have devtmpfs.
#   - No chown here; fakeroot during cpio handles ownership.

set -eu

die(){ echo "ERROR: $*" >&2; exit 1; }
warn(){ echo "WARN: $*" >&2; }
msg(){ [ "${VERBOSE:-0}" = "1" ] && echo "$*" >&2 || :; }
abs(){ (cd "$(dirname -- "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$1")"); }

STAGE_ROOT= INIT_SRC= README_INIT= README_PAY= BUSYBOX_BIN= FILES_DIR= TINYOS_CONF=
VERBOSE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage-root)       STAGE_ROOT="$2"; shift 2;;
    --init)             INIT_SRC="$2"; shift 2;;
    --busybox)          BUSYBOX_BIN="$2"; shift 2;;
    --readme-initramfs) README_INIT="$2"; shift 2;;
    --readme-payload)   README_PAY="$2"; shift 2;;
    --files-dir)        FILES_DIR="$2"; shift 2;;
    --tinyos-conf)      TINYOS_CONF="$2"; shift 2;;
    --verbose|-v)       VERBOSE=1; shift;;
    --help|-h)          sed -n '1,220p' "$0"; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

[ -n "$STAGE_ROOT" ]  || die "--stage-root is required"
[ -n "$INIT_SRC" ]    || die "--init is required"
[ -n "$BUSYBOX_BIN" ] || die "--busybox is required"

STAGE_ROOT="$(abs "$STAGE_ROOT")"
INIT_SRC="$(abs "$INIT_SRC")"
BUSYBOX_BIN="$(abs "$BUSYBOX_BIN")"
[ -n "${README_INIT:-}" ] && README_INIT="$(abs "$README_INIT")" || :
[ -n "${README_PAY:-}" ]  && README_PAY="$(abs "$README_PAY")" || :
[ -n "${FILES_DIR:-}" ]   && FILES_DIR="$(abs "$FILES_DIR")" || :
[ -n "${TINYOS_CONF:-}" ] && TINYOS_CONF="$(abs "$TINYOS_CONF")" || :

[ -f "$INIT_SRC" ]    || die "init not found: $INIT_SRC"
[ -x "$BUSYBOX_BIN" ] || die "busybox not executable: $BUSYBOX_BIN"
[ -z "${FILES_DIR:-}" ] || [ -d "$FILES_DIR" ] || die "--files-dir not a directory: $FILES_DIR"
[ -z "${TINYOS_CONF:-}" ] || [ -f "$TINYOS_CONF" ] || die "--tinyos-conf not found: $TINYOS_CONF"

INITRAMFS_DIR="$STAGE_ROOT/initramfs"
PAYLOAD_DIR="$STAGE_ROOT/payload"
mkdir -p "$INITRAMFS_DIR"/{etc/init.d,proc,sys,dev,bin} "$PAYLOAD_DIR"

# Guard: refuse overlays that try to drop core binaries
check_overlay_conflicts() {
  ov="$1"
  [ -d "$ov" ] || return 0
  if [ -e "$ov/init" ] || [ -e "$ov/sbin/init" ] || [ -e "$ov/bin/init" ] || \
    [ -e "$ov/bin/busybox" ] || [ -e "$ov/sbin/busybox" ]; then
    die "overlay '$ov' attempts to overwrite core binaries (/init, /sbin/init, /bin/init, or /bin/busybox)"
  fi
}

copy_tree(){ # src dest
  [ -d "$1" ] || return 0
  # tar-pipe works with busybox tar and preserves layout
  (cd "$1" && tar -cf - .) | (cd "$2" && tar -xf -)
}

# 1) BusyBox init scaffolding FIRST (allow overlays to override later)
#    Note: This script symlinks /sbin/init -> /init, so the kernel can find
#    it. At runtime, /init overrides /sbin/init -> /bin/busybox immediately
#    before handing off to busybox init.
cat >"$INITRAMFS_DIR/etc/inittab" <<'INITTAB'
console::respawn:/bin/sh
tty0::askfirst:/bin/sh
tty1::askfirst:/bin/sh
tty2::askfirst:/bin/sh
tty3::askfirst:/bin/sh
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
::restart:/sbin/init
INITTAB
chmod 0644 "$INITRAMFS_DIR/etc/inittab"

# 2) Overlays (only the two subdirectories so they can override inittab/rcS if desired)
if [ -n "${FILES_DIR:-}" ]; then
  if [ -d "$FILES_DIR/initramfs" ]; then
    check_overlay_conflicts "$FILES_DIR/initramfs"
    msg "overlay: $FILES_DIR/initramfs → $INITRAMFS_DIR"
    copy_tree "$FILES_DIR/initramfs" "$INITRAMFS_DIR"
  fi
  if [ -d "$FILES_DIR/payload" ]; then
    check_overlay_conflicts "$FILES_DIR/payload"
    msg "overlay: $FILES_DIR/payload → $PAYLOAD_DIR"
    copy_tree "$FILES_DIR/payload" "$PAYLOAD_DIR"
  fi
fi

# 2.1) Install README files, if not overridden by overlay
if [ ! -e "$INITRAMFS_DIR/README" ] && [ -f "$README_INIT" ]; then
  msg "emit: README → $INITRAMFS_DIR/README"
  install -m 644 "$README_INIT" "$INITRAMFS_DIR/README"
fi
if [ ! -e "$PAYLOAD_DIR/README" ] && [ -f "$README_PAY" ]; then
  msg "emit: README → $PAYLOAD_DIR/README"
  install -m 644 "$README_PAY" "$PAYLOAD_DIR/README"
fi

# 3) Lightweight FHS symlinks if available (do not clobber real /usr)
# Unconditionally merge /bin and /sbin; /bin wins
TMPBIN="$(mktemp -d "$INITRAMFS_DIR/.bin.XXXXXX")"
# move contents of /sbin then /bin into TMPBIN, if any
for d in "$INITRAMFS_DIR/sbin" "$INITRAMFS_DIR/bin"; do
  [ -d "$d" ] || continue
  # move non-hidden and hidden (excluding . and ..)
  for f in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    [ -e "$f" ] || continue
    mv -f "$f" "$TMPBIN"/
  done
  [ -h "$d" ] && rm -f "$d" || rmdir "$d"
done
mv -f "$TMPBIN" "$INITRAMFS_DIR/bin"
ln -snf bin "$INITRAMFS_DIR/sbin"

# /usr/bin → /bin ; /usr/sbin → /bin (don't clobber existing directories)
[ -d "$INITRAMFS_DIR/usr" ]      || mkdir -p "$INITRAMFS_DIR/usr"
[ -d "$INITRAMFS_DIR/usr/bin" ]  || ln -snf ../bin "$INITRAMFS_DIR/usr/bin"
[ -d "$INITRAMFS_DIR/usr/sbin" ] || ln -snf ../bin "$INITRAMFS_DIR/usr/sbin"

# 4) Authoritative init + busybox LAST (avoid overlay shadowing)
#    Enforce single canonical init at /init, with compatibility link at /sbin/init.
[ ! -e "$INITRAMFS_DIR/etc/init"  ] || rm -f "$INITRAMFS_DIR/etc/init"
[ ! -e "$INITRAMFS_DIR/sbin/init" ] || rm -f "$INITRAMFS_DIR/sbin/init"
[ ! -e "$INITRAMFS_DIR/bin/init"  ] || rm -f "$INITRAMFS_DIR/bin/init"
[ ! -e "$INITRAMFS_DIR/init"      ] || rm -f "$INITRAMFS_DIR/init"
msg "install: $INIT_SRC → $INITRAMFS_DIR/init"
{
  printf '#!/bin/busybox sh\n'
  printf '# ------------------------------------------------------------------\n'
  printf '# Generated by stage-assets.sh from %s on %s\n' "$parts_dir" "$(date -u)"
  printf '# Do not edit this file; edit the parts instead.\n'
  printf '# ------------------------------------------------------------------\n\n'

  find "$INIT_SRC" -maxdepth 1 -type f -print0 \
  | sort -z \
  | while read -d '' part; do
      awk -v part="$(basename "$part")" '
        BEGIN {
          printf "# --- BEGIN %s ------------\n\n", part
        }
        NR==1 && $0~/^#!/ {
          # Skip per-part shebang
          next
        }
        {
          # Normalize CRLF -> LF
          sub(/\r$/, ""); print
        }
        END {
          printf "\n# --- END %s --------------\n", part
        }
      ' < "$part"
    done
} > "$INITRAMFS_DIR/init"
chmod 0755 "$INITRAMFS_DIR/init"
ln -sf ../init "$INITRAMFS_DIR/sbin/init"

msg "install: $BUSYBOX_BIN → $INITRAMFS_DIR/bin/busybox"
install -m 0755 "$BUSYBOX_BIN" "$INITRAMFS_DIR/bin/busybox"
ln -sf busybox "$INITRAMFS_DIR/bin/sh"

# 4) tinyos.conf ONLY to initramfs
if [ -n "${TINYOS_CONF:-}" ]; then
  msg "install: tinyos.conf → $INITRAMFS_DIR/etc/tinyos.conf"
  install -m 0644 "$TINYOS_CONF" "$INITRAMFS_DIR/etc/tinyos.conf"
fi

msg "assets staged (scaffolding → overlays → init+busybox → tinyos.conf)"
