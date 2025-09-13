#!/usr/bin/env bash
# pack-initramfs.sh — TinyOS initramfs packer (no-mtime; fakeroot required)
#
# NOTE: requires fakeroot; uses -mindepth to avoid empty-name cpio entry.
#
# Purpose:
#   Pick up an already-staged initramfs tree and pack it into a compressed image.
#   (All staging — init, busybox, files, modules, firmware, layout — is handled
#    by stage-assets.sh and friends.)
#
# Design:
#   • Do NOT rewrite mtimes. We only sort paths for stable ordering.
#   • Use cpio "newc" with forced numeric owner 0:0 (root:root).
#   • Hard dependency on fakeroot to serialize device nodes/modes correctly.
#   • Minimal required device nodes (/dev/console, /dev/null) are staged here.
#   • Compressor can be auto-detected from the target kernel .config (COMP=auto).
#
# Usage:
#   ./pack-initramfs.sh --root STAGE_DIR --out OUT_IMG
#   (Backward-compat: positional [STAGE_DIR] [OUT_IMG] still accepted)
#
# Env knobs:
#   COMP=auto|zstd|xz|lz4|gzip|none   # Default: auto (read kernel .config)
#   KERNEL_CONFIG=/path/to/.config    # Optional explicit path to kernel .config
#   VERBOSE=1                         # Chatty logging to stderr
#   LISTING=1                         # Emit sorted file list alongside the image
#
# Dotfile artifacts (written into STAGE_DIR):
#   .initramfs.comp     – chosen compressor
#   .initramfs.summary  – one-line summary (out, comp, fakeroot, files, dirs, size)

set -euo pipefail

log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[pack-initramfs] $*" >&2 || true; }
err(){ echo "[pack-initramfs] ERROR: $*" >&2; exit 1; }

: "${COMP:=auto}"

# Args (support both flags and legacy positionals)
STAGE_DIR=""
OUT_IMG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) STAGE_DIR="${2:?}"; shift 2 ;;
    --out)  OUT_IMG="${2:?}"; shift 2 ;;
    -v|--verbose) VERBOSE=$(( ${VERBOSE:-0} + 1 )); shift ;;
    -h|--help) sed -n '1,120p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
# legacy positionals
if [ -z "$STAGE_DIR" ]; then STAGE_DIR="${1:-staging}"; shift 2 >/dev/null 2>&1 || true; fi
if [ -z "$OUT_IMG"  ]; then OUT_IMG="${OUT_IMG:-${1:-initramfs.img}}"; fi

[ -d "$STAGE_DIR" ] || err "Stage dir '$STAGE_DIR' not found"

# Normalize OUT_IMG to an absolute path and ensure its parent exists.
case "$OUT_IMG" in
  /*) OUT_ABS="$OUT_IMG" ;;
  *)  OUT_ABS="$(cd -P . && printf '%s/%s' "$(pwd)" "$OUT_IMG")" ;;
esac
mkdir -p "$(dirname -- "$OUT_ABS")" 2>/dev/null || true

# Record summary against the absolute output, so logs/readbacks are consistent.
SUMMARY_TARGET="$OUT_ABS"

# Viability checks: require init and BusyBox in the staged tree
[ -x "$STAGE_DIR/init" ] || err "Missing $STAGE_DIR/init (executable)"
if [ ! -x "$STAGE_DIR/bin/busybox" ] && [ ! -x "$STAGE_DIR/sbin/busybox" ]; then
  err "Missing BusyBox binary (expected at bin/busybox or sbin/busybox)"
fi

# Hard dependency on fakeroot
command -v fakeroot >/dev/null 2>&1 || err "fakeroot is required but not found"

# Dotfile outputs
SUMMARY_FILE="$STAGE_DIR/.initramfs.summary"
COMP_FILE="$STAGE_DIR/.initramfs.comp"
: >"$COMP_FILE" 2>/dev/null || true
: >"$SUMMARY_FILE" 2>/dev/null || true

# Auto-detect compressor from kernel config if COMP=auto
CFG_PATH=""
if [ "$COMP" = auto ]; then
  cfg="${KERNEL_CONFIG:-}"
  # Default to project-local linux/.config if not specified
  if [ -z "$cfg" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$SCRIPT_DIR/../linux/.config" ]; then
      cfg="$SCRIPT_DIR/../linux/.config"
    fi
  fi
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    CFG_PATH="$cfg"
    if   grep -q '^CONFIG_RD_ZSTD=y' "$cfg"; then COMP=zstd
    elif grep -q '^CONFIG_RD_XZ=y'   "$cfg"; then COMP=xz
    elif grep -q '^CONFIG_RD_LZ4=y'  "$cfg"; then COMP=lz4
    elif grep -q '^CONFIG_RD_GZIP=y' "$cfg"; then COMP=gzip
    else COMP=none; fi
    echo "$COMP" >"$COMP_FILE" || true
    log "auto: using compressor $COMP from $cfg"
  else
    COMP=gzip
    echo "$COMP" >"$COMP_FILE" || true
    log "auto: kernel config not found; defaulting COMP=$COMP"
  fi
else
  echo "$COMP" >"$COMP_FILE" || true
fi

# Sanity-check that the kernel supports the chosen compressor
if [ -n "$CFG_PATH" ] && [ -f "$CFG_PATH" ]; then
  case "$COMP" in
    zstd)  grep -q '^CONFIG_RD_ZSTD=y' "$CFG_PATH" || err "Kernel .config does not support zstd" ;;
    xz)    grep -q '^CONFIG_RD_XZ=y'   "$CFG_PATH" || err "Kernel .config does not support xz" ;;
    lz4)   grep -q '^CONFIG_RD_LZ4=y'  "$CFG_PATH" || err "Kernel .config does not support lz4" ;;
    gzip)  grep -q '^CONFIG_RD_GZIP=y' "$CFG_PATH" || err "Kernel .config does not support gzip" ;;
    none)  : ;;
    *)     : ;;
  esac
fi

# Choose compressor (sanity-check availability)
compress(){
  case "$COMP" in
    zstd)  command -v zstd >/dev/null 2>&1 || err "zstd not found";  log "comp: zstd -19"; zstd -q -19 -T0 ;;
    xz)    command -v xz   >/dev/null 2>&1 || err "xz not found";    log "comp: xz -9e";   xz -9e -T0 ;;
    lz4)   command -v lz4  >/dev/null 2>&1 || err "lz4 not found";   log "comp: lz4 -12";  lz4 -12 -q ;;
    gzip)  command -v gzip >/dev/null 2>&1 || err "gzip not found";  log "comp: gzip -9n"; gzip -9n ;;
    none)  log "comp: none"; cat ;;
    *)     err "Unknown COMP='$COMP'" ;;
  esac
}

# Pre-pack scan stats (also record to summary)
FILES_TOTAL=$(find "$STAGE_DIR" -xdev -type f | wc -l | tr -d '[:space:]' || echo 0)
DIRS_TOTAL=$(find "$STAGE_DIR" -xdev -type d | wc -l | tr -d '[:space:]' || echo 0)
if [ "${VERBOSE:-0}" = 1 ]; then
  log "scan: $FILES_TOTAL files across $DIRS_TOTAL dirs"
fi

if [ "$FILES_TOTAL" -eq 0 ]; then
  err "Stage directory '$STAGE_DIR' is empty — did you point me at the wrong place?"
fi

echo "out:$OUT_ABS comp:$COMP fakeroot:1 files:$FILES_TOTAL dirs:$DIRS_TOTAL" >"$SUMMARY_FILE" || true

log "Packing initramfs from '$STAGE_DIR' → '$OUT_ABS' (COMP=$COMP, fakeroot=1)"
(
  cd "$STAGE_DIR" >/dev/null
  # Create minimal device nodes under fakeroot just before archiving
  fakeroot -- sh -c '
    set -e
    mkdir -p dev
    [ -c dev/console ] || mknod -m 600 dev/console c 5 1
    [ -c dev/null ]    || mknod -m 666 dev/null    c 1 3
    chown -R root:root .
    # IMPORTANT: -mindepth 1 prevents the empty name for "." which breaks cpio.
    LC_ALL=C find . -mindepth 1 -printf '\''%P\0'\'' \
      | LC_ALL=C sort -z \
      | cpio -0 -o --format=newc # 2>/dev/null
  ' | compress >"$OUT_ABS"
)

# Helpful size note and finalize summary
if command -v du >/dev/null 2>&1; then
  SZ=$(du -h "$OUT_ABS" | awk '{print $1}')
  log "Wrote $OUT_ABS ($SZ)"
  sed -i "1s/$/ size:$SZ/" "$SUMMARY_FILE" 2>/dev/null || echo " size:$SZ" >>"$SUMMARY_FILE"
fi

# Optional: emit sorted file listing
if [ -n "${LISTING:-}" ]; then
  ( cd "$STAGE_DIR" && LC_ALL=C find . -printf '%P\\n' | LC_ALL=C sort ) >"$OUT_ABS.files"
  log "File listing: $OUT_ABS.files"
  if [ ! -s "$OUT_ABS.files" ]; then
    err "Generated file listing is empty — did you stage the wrong directory?"
  fi
fi

log "Done. Embed this initramfs into your kernel/EFI image."
