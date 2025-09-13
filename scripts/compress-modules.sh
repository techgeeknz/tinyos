#!/usr/bin/env bash
set -euo pipefail
# Normalize & compress modules directory.
# - Ensures every entry in --keep-list exists as plain .ko (decompress if needed).
# - Creates compressed copies (.ko.$ext) for every entry in --copy-list if tool!=none.
# - Compresses remaining .ko files (excluding --keep-list and --exclude-list) in place.
#
# Usage:
#   compress-modules.sh --modules-dir /.../lib/modules/KVER \
#     --tool gzip|xz|zstd|none \
#     [--keep-list FILE] [--copy-list FILE] [--exclude-list FILE]

VERBOSE=${VERBOSE:-0}
MODDIR= TOOL= KEEP= COPY= EXCL=
log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[compress-modules] $*" >&2 || true; }

while [ $# -gt 0 ]; do
  case "$1" in
    --modules-dir) MODDIR=${2:?}; shift 2 ;;
    --tool) TOOL=${2:?}; shift 2 ;;
    --keep-list) KEEP=${2:?}; shift 2 ;;
    --copy-list) COPY=${2:?}; shift 2 ;;
    --exclude-list) EXCL=${2:?}; shift 2 ;;
    --verbose) VERBOSE=1; shift;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODDIR$TOOL" ] || { echo "missing args" >&2; exit 2; }
[ -d "$MODDIR" ] || { echo "modules dir not found: $MODDIR" >&2; exit 1; }

# helpers
to_base() { local p=$1; p=${p%.zst}; p=${p%.xz}; p=${p%.gz}; [[ $p == *.ko ]] || p="${p%.ko}.ko"; echo "$p"; }
decompress_if_needed() {
  local base="$1"
  [ -f "$base" ] && return 0
  [ -f "$base.zst" ] && { zstd -q -d "$base.zst" -o "$base"; return 0; } || true
  [ -f "$base.xz"  ] && { unxz -q -k "$base.xz" || xz -d -q -k "$base.xz"; return 0; } || true
  [ -f "$base.gz"  ] && { gunzip -c "$base.gz" >"$base"; return 0; } || true
  return 1
}

compress_inplace() {
  local tool="$1" ext="$2" f="$3"
  case "$tool" in
    zstd) zstd -q --rm -19 --no-progress "$f" ;;
    xz)   xz -T0 -q -9e "$f" ;;
    gzip) gzip -n -9 "$f" ;;
    none|'') : ;;
    *) echo "unknown tool: $tool" >&2; exit 2 ;;
  esac
}

write_copy() {
  local tool="$1" ext="$2" base="$3" comp="$3.$2"
  case "$tool" in
    zstd) zstd -q --rm=false -19 --no-progress -o "$comp" -- "$base" ;;
    xz)   xz -T0 -q -9e -c -- "$base" >"$comp" ;;
    gzip) gzip -n -9 -c -- "$base" >"$comp" ;;
    none|'') : ;;
  esac
}

ext=""
case "$TOOL" in
  gzip) ext="gz" ;;
  xz)   ext="xz" ;;
  zstd) ext="zst" ;;
  none|'') ext="" ;;
  *) echo "invalid --tool: $TOOL" >&2; exit 2 ;;
esac

# ensure selected compressor exists; otherwise fall back to none
if [ -n "$ext" ] && ! command -v "$TOOL" >/dev/null 2>&1; then
  echo "WARN: compressor '$TOOL' not found; falling back to none" >&2
  TOOL="none"; ext=""
fi

contains() { local needle="$1" list="$2"; grep -qx -- "$needle" "$list" 2>/dev/null; }

# Normalize keep-list to plain .ko and drop compressed siblings
if [ -n "${KEEP:-}" ] && [ -s "$KEEP" ]; then
  log "Ensuring plain .ko for keep-list (initramfs)"
  while IFS= read -r rel; do
    base="$MODDIR/$(to_base "$rel")"
    if ! decompress_if_needed "$base"; then
      echo "ERROR: missing module for keep-list: $rel" >&2; exit 1
    fi
    rm -f "$base.zst" "$base.xz" "$base.gz" 2>/dev/null || true
  done <"$KEEP"
fi

# Create compressed copies for copy-list (if tool selected)
if [ -n "$ext" ] && [ -n "${COPY:-}" ] && [ -s "$COPY" ]; then
  log "Writing compressed copies for copy-list (.$ext)"
  while IFS= read -r rel; do
    base="$MODDIR/$(to_base "$rel")"; [ -f "$base" ] || continue
    comp="$base.$ext"
    if [ ! -f "$comp" ] || [ "$base" -nt "$comp" ]; then
      write_copy "$TOOL" "$ext" "$base"
    fi
  done <"$COPY"
fi

# Compress remaining non-keep .ko (excluding EXCL if provided)
if [ -n "$ext" ]; then
  log "Compressing non-closure modules with .$ext"
  find "$MODDIR" -type f -name '*.ko' -print | while IFS= read -r f; do
    rel="${f#"$MODDIR/"}"
    if [ -n "${KEEP:-}" ] && contains "$rel" "$KEEP"; then continue; fi
    if [ -n "${EXCL:-}" ] && contains "$rel" "$EXCL"; then continue; fi
    rm -f "$f.zst" "$f.xz" "$f.gz" 2>/dev/null || true
    compress_inplace "$TOOL" "$ext" "$f"
  done
fi
