#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
STAGED_KVER="$SCRIPT_DIR/staged-kver.sh"

MODDIR=""   # may be .../lib/modules or .../lib/modules/<KVER>
KVER=""     # optional; if absent we derive from staged tree
VERBOSE=${VERBOSE:-0}

log(){ [ "$VERBOSE" -gt 0 ] && echo "[depmod-safe] $*" >&2 || true; }
die(){ echo "[depmod-safe] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --modules-dir) MODDIR="$2"; shift 2 ;;
    --kver)        KVER="$2";   shift 2 ;;
    -v|--verbose)  VERBOSE=$((VERBOSE+1)); shift ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[ -n "$MODDIR" ] || die "--modules-dir required"

if [ -d "$MODDIR/kernel" ]; then
  # Caller passed .../lib/modules/<KVER>
  KVER_FROM_PATH="$(basename "$MODDIR")"
  MODROOT="$(cd -- "$MODDIR/../../.." && pwd)"   # base dir containing lib/modules
elif [ -d "$MODDIR" ]; then
  # Caller passed base .../lib/modules
  # (parent of this dir is the depmod -b root)
  MODROOT="$(cd -- "$MODDIR/../.." && pwd)"
  KVER_FROM_PATH=""
else
  die "--modules-dir must be '.../lib/modules' or '.../lib/modules/<KVER>' (got: $MODDIR)"
fi
log "MODDIR:  $MODDIR"
log "MODROOT: $MODROOT"

[ -n "$KVER" ] || { [ -x "$STAGED_KVER" ] || die "missing helper: $STAGED_KVER"; KVER="$("$STAGED_KVER" --modules-root "$MODROOT/lib/modules" --one ${VERBOSE:+--verbose})"; }
[ -d "$MODROOT/lib/modules/$KVER" ] || die "Missing tree: $MODROOT/lib/modules/$KVER"

log "Running: depmod -b '$MODROOT' '$KVER'"
# Capture stderr to inspect for benign cycle warnings
TMPERR=$(mktemp); trap 'rm -f "$TMPERR"' EXIT
if depmod -b "$MODROOT" "$KVER" 2>"$TMPERR"; then
  log "depmod ok"
  exit 0
fi

if grep -qEi 'Cycle detected' "$TMPERR" && ! grep -qEiv 'Cycle detected' "$TMPERR"; then
  echo "[depmod-safe] WARN: depmod reported module dependency cycle(s); treating as non-fatal." >&2
  sed -n '1,200p' "$TMPERR" >&2
  exit 0
fi

echo "[depmod-safe] depmod failed:" >&2
sed -n '1,200p' "$TMPERR" >&2
exit 1
