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

TMPERR=$(mktemp); trap "rm -f '$TMPERR'" EXIT
for attempt in 1 2 3; do
  log "Running: depmod -b '$MODROOT' '$KVER'"
  # Capture stderr to inspect for benign cycle warnings
  if depmod -b "$MODROOT" "$KVER" 2> >(tee "$TMPERR" >&2); then
    log "depmod succeeded on attempt $attempt"
    exit 0
  fi

  # Quarantine dependency cycles
  awk '
  /Cycle detected:/ {
    gsub(/^.*Cycle detected:|->|[[:space:]][[:space:]]}/, " ", $0);
    n = split($0, m); for (i = 1; i <= n; i++) print m[i];
  }' < "$TMPERR" | sort -u |
  while read module; do
    log "quarantining module: $module"
    mkdir -p "$MODROOT/lib/modules/$KVER.disabled"
    find "$MODROOT/lib/modules/$KVER" -type f -name "${module}.ko*" -print0 |
    xargs -r0 mv -t "$MODROOT/lib/modules/$KVER.disabled"
  done
done

die "depmod failed after $attempt attempts"
