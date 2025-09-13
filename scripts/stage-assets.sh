#!/usr/bin/env sh
# stage-assets.sh — stage init/busybox and config overlays into staging
# Usage:
#   stage-assets.sh \
#     --stage-root        /abs/path/to/staging \
#     --init              ./rootfs/init \
#     --busybox           /abs/path/to/busybox \
#     [--readme-initramfs ./rootfs/README.initramfs] \
#     [--readme-payload   ./rootfs/README.payload] \
#     [--files-dir        ./config/files]         # expects subdirs: initramfs/ and payload/ \
#     [--tinyos-conf      ./config/tinyos.conf]   # written ONLY to initramfs/etc/tinyos.conf \
#     [--verbose] [--dry-run]
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
run(){ if [ "${DRYRUN:-0}" = "1" ]; then echo "+ $*"; else sh -c "$*"; fi; }
abs(){ (cd "$(dirname -- "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$1")"); }

STAGE_ROOT= INIT_SRC= README_INIT= README_PAY= BUSYBOX_BIN= FILES_DIR= TINYOS_CONF=
VERBOSE=0 DRYRUN=0

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
    --dry-run)          DRYRUN=1; shift;;
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
run "mkdir -p '$INITRAMFS_DIR/etc/init.d' '$PAYLOAD_DIR'"

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
cat >"$INITRAMFS_DIR/etc/inittab" <<'INITTAB'
::sysinit:/etc/init.d/rcS
tty1::respawn:/bin/sh
tty2::respawn:/bin/sh
tty3::respawn:/bin/sh
tty4::respawn:/bin/sh
tty5::respawn:/bin/sh
tty6::respawn:/bin/sh
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
INITTAB
chmod 0644 "$INITRAMFS_DIR/etc/inittab"

# rcS: only mount proc/sys/dev if not already mounted (use busybox mountpoint)
cat >"$INITRAMFS_DIR/etc/init.d/rcS" <<'RCS'
#!/bin/sh
set -eu

mp() { busybox mountpoint -q "$1"; }  # returns 0 if mounted

[ -d /proc ] || mkdir -p /proc
[ -d /sys  ] || mkdir -p /sys
[ -d /dev  ] || mkdir -p /dev

mp /proc || mount -t proc     proc     /proc  || true
mp /sys  || mount -t sysfs    sysfs    /sys   || true
mp /dev  || mount -t devtmpfs devtmpfs /dev   || true

exit 0
RCS
chmod 0755 "$INITRAMFS_DIR/etc/init.d/rcS"

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
if [ ! -f "$INITRAMFS_DIR/README" ] && [ -f "$README_INIT" ]; then
  msg "emit: README → $INITRAMFS_DIR/README"
  run "install -m 644 '$README_INIT' '$INITRAMFS_DIR/README'"
fi
if [ ! -f "$PAYLOAD_DIR/README" ] && [ -f "$README_PAY" ]; then
  msg "emit: README → $PAYLOAD_DIR/README"
  run "install -m 644 '$README_PAY' '$PAYLOAD_DIR/README'"
fi

# 3) Authoritative init + busybox LAST (avoid overlay shadowing)
#    Enforce single canonical init at /init, with compatibility link at /sbin/init.
run "mkdir -p '$INITRAMFS_DIR/sbin' '$INITRAMFS_DIR/bin' '$INITRAMFS_DIR/etc'"
# Remove any stray inits that overlays may have tried to add indirectly.
[ -e "$INITRAMFS_DIR/sbin/init" ] && run "rm -f '$INITRAMFS_DIR/sbin/init'"
[ -e "$INITRAMFS_DIR/bin/init"  ] && run "rm -f '$INITRAMFS_DIR/bin/init'"
[ -e "$INITRAMFS_DIR/init"      ] && run "rm -f '$INITRAMFS_DIR/init'"
msg "install: $INIT_SRC → $INITRAMFS_DIR/init"
run "install -m 0755 '$INIT_SRC' '$INITRAMFS_DIR/init'"
# Provide compatibility path for userspace that still expects /sbin/init.
[ -L "$INITRAMFS_DIR/sbin/init" ] || run "ln -sf ../init '$INITRAMFS_DIR/sbin/init'"

# 3.1) Lightweight FHS symlinks if available (do not clobber real /usr)
# /sbin → /bin (move contents if any, then replace with symlink)
if [ -d "$INITRAMFS_DIR/sbin" ] && [ ! -L "$INITRAMFS_DIR/sbin" ]; then
  # Move files if the dir isn't empty (ignore “No such file” on empty)
  run "set -f; mv '$INITRAMFS_DIR'/sbin/* '$INITRAMFS_DIR/bin/' 2>/dev/null || true; set +f"
  run "rmdir '$INITRAMFS_DIR/sbin' 2>/dev/null || rm -rf '$INITRAMFS_DIR/sbin'"
fi
run "ln -snf bin '$INITRAMFS_DIR/sbin'"

# /usr/bin → /bin ; /usr/sbin → /bin
if [ ! -d "$INITRAMFS_DIR/usr" ]; then
  run "mkdir -p '$INITRAMFS_DIR/usr'"
fi
if [ ! -d "$INITRAMFS_DIR/usr/bin" ] || [ -h "$INITRAMFS_DIR/usr/bin" ]; then
  [ -h "$INITRAMFS_DIR/usr/bin" ] || run "ln -snf ../bin '$INITRAMFS_DIR/usr/bin'"
fi
if [ ! -d "$INITRAMFS_DIR/usr/sbin" ] || [ -h "$INITRAMFS_DIR/usr/sbin" ]; then
  [ -h "$INITRAMFS_DIR/usr/sbin" ] || run "ln -snf ../bin '$INITRAMFS_DIR/usr/sbin'"
fi

msg "install: $BUSYBOX_BIN → $INITRAMFS_DIR/bin/busybox"
run "install -m 0755 '$BUSYBOX_BIN' '$INITRAMFS_DIR/bin/busybox'"
[ -L "$INITRAMFS_DIR/bin/sh" ] || run "ln -sf busybox '$INITRAMFS_DIR/bin/sh'"

# 4) tinyos.conf ONLY to initramfs
if [ -n "${TINYOS_CONF:-}" ]; then
  msg "install: tinyos.conf → $INITRAMFS_DIR/etc/tinyos.conf"
  run "install -m 0644 '$TINYOS_CONF' '$INITRAMFS_DIR/etc/tinyos.conf'"
fi

msg "assets staged (scaffolding → overlays → init+busybox → tinyos.conf)"
