#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2312

# Locate helper scripts relative to this file
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IS_EFI_APP="${SCRIPT_DIR}/is-efi-app.sh"
[ -x "$IS_EFI_APP" ] || IS_EFI_APP=""  # graceful fallback if missing

STAGE_STAMP=""
PAYLOAD=""
TOOLS_MOUNT=""
TINYOS_REL=""
MANIFEST=".tinyos.manifest"
BACKUPS=".backup"
VERBOSE=${VERBOSE:-0}

# --- helpers ---------------------------------------------------------------
trim_ws() { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
norm_slashes() { printf '%s' "$1" | sed -E 's:/+:/:g'; }
strip_leading_slash() { printf '%s' "$1" | sed -E 's:^/+::'; }
join_path() {
  # join_path /a/b  c/d  -> /a/b/c/d   (without duplicating /)
  norm_slashes "$(printf '%s/%s' "$1" "$2")"
}
is_vfat_component_bad() {
  # Reject components that are '.' or '..' or end in space/dot
  # (VFAT dislikes trailing spaces/dots in names)
  local c="$1"
  case "$c" in
    '.'|'..') return 0;;
  esac
  [[ "$c" =~ [[:space:]]$ ]] && return 0
  [[ "$c" =~ \.$ ]] && return 0
  return 1
}
validate_relpath() {
  IFS=/ read -r -a parts <<<"$(strip_leading_slash "$1")"
  for p in "${parts[@]}"; do is_vfat_component_bad "$p" && return 1; done; return 0
}
log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[install-payload] $*" >&2 || true; }
die(){ echo "[install-payload] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --stage-stamp) STAGE_STAMP="$2"; shift 2 ;;
    --payload)     PAYLOAD="$2";     shift 2 ;;
    --tools-mount) TOOLS_MOUNT="$2"; shift 2 ;;
    --tinyos-rel)  TINYOS_REL="$2";  shift 2 ;;
    --manifest)    MANIFEST="$2";    shift 2 ;;
    --backups)     BACKUPS="$2";     shift 2 ;;
    -v|--verbose)  VERBOSE=$((VERBOSE+1)); shift ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[ "$EUID" -eq 0 ] || die "'install' requires root; run: sudo make install"
[ -e "$STAGE_STAMP" ] || die "staging incomplete (need $STAGE_STAMP)"
[ -d "$PAYLOAD" ] || die "payload dir missing: $PAYLOAD"

TOOLS_MOUNT="$(norm_slashes "$(trim_ws "${TOOLS_MOUNT:-}")")"
case "$TOOLS_MOUNT" in /*) :;; *) die "TOOLS_MOUNT must be absolute (got '$TOOLS_MOUNT' )";; esac
# TINYOS_REL may come from a config file; sanitize hard.
TINYOS_REL="$(norm_slashes "$(strip_leading_slash "$(trim_ws "${TINYOS_REL:-}")")")"
[ -n "$TINYOS_REL" ] || die "TINYOS_REL must be non-empty"
validate_relpath "$TINYOS_REL" || die "TINYOS_REL contains illegal VFAT components: '$TINYOS_REL'"

# Normalize TOOLS_MOUNT (drop trailing slashes) and build final base dir
TOOLS_MOUNT="${TOOLS_MOUNT%/}"
BD="$(join_path "$TOOLS_MOUNT" "$TINYOS_REL")"
log "TOOLS_MOUNT='$TOOLS_MOUNT'  TINYOS_REL='$TINYOS_REL'  →  BD='$BD'"

if ! mountpoint -q "$TOOLS_MOUNT"; then
  die "HP_TOOLS is not mounted at $TOOLS_MOUNT (mount -t vfat /dev/sdXN '$TOOLS_MOUNT')"
fi
if ! findmnt -nr -t vfat,msdos,exfat,ntfs -T "$TOOLS_MOUNT" >/dev/null 2>&1; then
  echo "[install-payload] WARN: $TOOLS_MOUNT is not a FAT-like FS (proceeding)" >&2
fi

# Final sanity: refuse to operate if BD resolved to the mount root
case "$BD" in
  "$TOOLS_MOUNT"|"$TOOLS_MOUNT/") die "Refusing to sync into mount root ('$BD'); set a subdirectory in TINYOS_REL." ;;
esac

# Verify we have at least one EFI Application in payload (by content)
shopt -s nullglob
has_efi=0
if [ -x "$IS_EFI_APP" ]; then
  # First pass: explicit *.efi files via parser
  if [ $has_efi -eq 0 ]; then
    while IFS= read -r -d '' f; do
      if "$IS_EFI_APP" "$f" 2>/dev/null; then has_efi=1; break; fi
    done < <(find "$PAYLOAD" -maxdepth 1 -type f -iname '*.efi' -print0)
  fi
  # Second pass: any file at payload root (covers kernels named oddly)
  if [ $has_efi -eq 0 ]; then
    while IFS= read -r -d '' f; do
      if "$IS_EFI_APP" "$f" 2>/dev/null; then has_efi=1; break; fi
    done < <(find "$PAYLOAD" -maxdepth 1 -type f -print0)
  fi
else
  # Last-chance fallback: if the parser isn’t present, look for any *.efi file
  shopt -s nullglob
  set -- "$PAYLOAD"/*.efi "$PAYLOAD"/*.EFI
  [ "$#" -gt 0 ] && has_efi=1
fi
[ $has_efi -eq 1 ] || die "no EFI application found in $PAYLOAD"

install -d -m 0755 "$BD"
log "Install destination validated: $BD"

# Build manifest of desired contents (relative paths)
TMAN="$(mktemp)"; trap 'rm -f "$TMAN"' EXIT
( cd "$PAYLOAD" && find . -type f -printf "%P\n" | LC_ALL=C sort -u ) >"$TMAN"

# Backup existing EFI apps (copy-then-delete; VFAT-safe)
stamp="$(date +%Y%m%d%H%M%S)"
bdir="$BD/$BACKUPS/tinyos-$stamp"
mkdir -p "$bdir"
if [ -x "$IS_EFI_APP" ]; then
  while IFS= read -r -d '' g; do
    if "$IS_EFI_APP" "$g" 2>/dev/null; then
      rel="${g#"$BD"/}"
      install -D -m 0644 "$g" "$bdir/$rel" && rm -f -- "$g"
    fi
  done < <(find "$BD" -maxdepth 1 -type f -print0)
else
  while IFS= read -r -d '' g; do
    rel="${g#"$BD"/}"
    install -D -m 0644 "$g" "$bdir/$rel" && rm -f -- "$g"
  done < <(find "$BD" -iname '*.efi' -maxdepth 1 -type f -print0)
fi
# prune empty backup dir
find "$BD/$BACKUPS" -depth -type d -empty -delete >/dev/null 2>&1 || true

echo "==> Syncing payload → $BD/"
# Choose rsync flags based on the destination filesystem:
# - On VFAT/EXFAT/NTFS: no ownership semantics → do not attempt to set owner/group.
# - On POSIX filesystems: force ownership to root:root while preserving perms/times/devs.
FSTYPE="$(findmnt -nr -T "$BD" -o FSTYPE 2>/dev/null || echo)"
case "$FSTYPE" in
  vfat|msdos|exfat|ntfs)
    # VFAT-like: no ownership. Also relax timestamp granularity with --modify-window.
    RSYNC_OPTS=(-rlptD --no-owner --no-group --modify-window=2 --omit-dir-times)
    OWN_FIX=0
    ;;
  *)
    # POSIX: preserve and force owner:group during transfer.
    # (rsync --chown requires rsync >= 3.1 on both ends; here both ends are local)
    RSYNC_OPTS=(-rlptD --chown=0:0)
    OWN_FIX=1
    ;;
esac
rsync "${RSYNC_OPTS[@]}" "$PAYLOAD/" "$BD/"

# As a belt-and-braces fallback on POSIX filesystems (e.g., if rsync --chown is missing),
# explicitly chown after the copy. Skip on VFAT-like targets.
if [ "$OWN_FIX" -eq 1 ]; then
  # Prefer not to touch symlink targets; use -h to change the link itself where supported.
  if chown -hR 0:0 "$BD" 2>/dev/null; then
    : # ok
  else
    # Portable fallback: avoid following symlinks
    find "$BD" -xdev -exec chown 0:0 {} + 2>/dev/null || true
  fi
fi

install -D -m 0644 "$TMAN" "$BD/$MANIFEST"
sync
echo "Installed: $BD/ (payload synced; manifest: $(basename "$MANIFEST"))"
