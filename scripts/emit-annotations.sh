#!/usr/bin/env bash
# emit-annotations.sh — Stage-Modules Step 7
#
# Purpose:
#   Generate annotated module lists and convenient copies from the outputs of
#   module-graph.sh and resolve-payload.sh. This provides human-readable context
#   (e.g. “# seed: earlyboot”) alongside machine-usable lists.
#
# Features:
#   • Annotates earlyboot (initramfs) and require closures.
#   • Marks explicitly excluded modules and those pruned as dependents.
#   • Normalizes compression suffixes (.ko.{zst,xz,gz}) to plain .ko.
#   • Produces stable, locale-independent sort order (LC_ALL=C).
#   • Writes empty annotation files if no data is present, ensuring predictable
#     artifacts.
#   • Copies both annotated files (.annot.*) and raw lists (.modules.*) into the
#     staging directory for quick inspection.
#
# Usage:
#   emit-annotations.sh --graph-dir DIR --lists-dir DIR --dest DIR [--verbose]
# -----------------------------------------------------------------------------

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: emit-annotations.sh \
  --graph-dir DIR   # where module-graph outputs live (.initramfs.*, .require.*) \
  --lists-dir DIR   # where resolve-payload outputs live (.exclude.*, .payload.*) \
  --dest DIR        # staging root (to receive .annot.* and .modules.* copies) \
  [--verbose]       # extra log lines to stderr \
  [--no-copies]     # skip convenience copies into --dest

Writes under --lists-dir:
  .initramfs.closure.annot          # initramfs closure with reasons (seed/dep-of)
  .require.closure.annot            # require closure with reasons (seed/dep-of)
  .exclude.resolved.annot           # resolved excludes (or empty file)
  .exclude.payload-closure.annot    # pruned dependents (or empty file)

Behavior notes:
  - Deterministic ordering (LC_ALL=C sort -u)
  - BusyBox-friendly normalization of *.ko[.zst|.xz|.gz]
  - Creates empty annotation files when inputs are absent, for predictable consumers
USAGE
}

log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[emit-annotations] $*" >&2 || true; }
err(){ echo "[emit-annotations] ERROR: $*" >&2; exit 1; }

GRAPH= LISTS= DEST= VERBOSE=0 NO_COPIES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --graph-dir) GRAPH=${2:?}; shift 2;;
    --lists-dir) LISTS=${2:?}; shift 2;;
    --dest)      DEST=${2:?};  shift 2;;
    --verbose)   VERBOSE=1;    shift;;
    --no-copies) NO_COPIES=1;  shift;;
    -h|--help)   usage; exit 0;;
    *) err "Unknown arg: $1";;
  esac
done

[ -n "$GRAPH" ] && [ -d "$GRAPH" ] || err "--graph-dir not found"
[ -n "$LISTS" ] && [ -d "$LISTS" ] || err "--lists-dir not found"
[ -n "$DEST" ]                     || err "--dest is required"
DEST_ABS="$(mkdir -p "$DEST" && cd "$DEST" && pwd)"

ANN_INIT="$LISTS/.initramfs.closure.annot"
ANN_REQ="$LISTS/.require.closure.annot"
ANN_EXC_RES="$LISTS/.exclude.resolved.annot"
ANN_EXC_PAY="$LISTS/.exclude.payload-closure.annot"

# Normalize helper (BusyBox-friendly, no -E)
normalize() { sed 's/\\.ko\\.zst$/.ko/;s/\\.ko\\.xz$/.ko/;s/\\.ko\\.gz$/.ko/;s/\\.ko$/.ko/'; }

# Annotate initramfs closure
{
  [ -f "$GRAPH/.initramfs.resolved" ] && awk '{print $0 " # seed: earlyboot"}' "$GRAPH/.initramfs.resolved" || true
  [ -f "$GRAPH/.initramfs.added_deps" ] && awk '{print $0 " # dep-of: earlyboot"}' "$GRAPH/.initramfs.added_deps" || true
} | normalize | LC_ALL=C sort -u > "$ANN_INIT" || true
log "wrote $ANN_INIT"

# Annotate require closure
{
  [ -f "$GRAPH/.require.resolved" ] && awk '{print $0 " # seed: require"}' "$GRAPH/.require.resolved" || true
  [ -f "$GRAPH/.require.added_deps" ] && awk '{print $0 " # dep-of: require"}' "$GRAPH/.require.added_deps" || true
} | normalize | LC_ALL=C sort -u > "$ANN_REQ" || true
log "wrote $ANN_REQ"

# Annotate excludes
if [ -f "$LISTS/.exclude.resolved" ]; then
  normalize < "$LISTS/.exclude.resolved" \
    | awk '{print $0 " # explicitly excluded"}' \
    | LC_ALL=C sort -u > "$ANN_EXC_RES" || true
  log "wrote $ANN_EXC_RES"
else
  : > "$ANN_EXC_RES"
fi

# Annotate payload pruned dependents (if present)
if [ -f "$LISTS/.payload.drop_dependents" ]; then
  normalize < "$LISTS/.payload.drop_dependents" \
    | awk '{print $0 " # pruned: depends-on excluded"}' \
    | LC_ALL=C sort -u > "$ANN_EXC_PAY" || true
  log "wrote $ANN_EXC_PAY"
else
  : > "$ANN_EXC_PAY"
fi

# Convenience copies into $DEST (optional)
if [ "$NO_COPIES" -eq 0 ]; then
  [ -f "$GRAPH/.initramfs.closure" ] && cp -af "$GRAPH/.initramfs.closure"  "$DEST_ABS/.modules.earlyboot.closure" 2>/dev/null || true
  [ -f "$GRAPH/.initramfs.modules" ] && cp -af "$GRAPH/.initramfs.modules"  "$DEST_ABS/.modules.initramfs.modules" 2>/dev/null || true
  [ -f "$GRAPH/.require.closure" ] && cp -af "$GRAPH/.require.closure" "$DEST_ABS/.modules.require.closure" 2>/dev/null || true
  [ -f "$LISTS/.payload.final" ] && cp -af "$LISTS/.payload.final" "$DEST_ABS/.modules.payload.final" 2>/dev/null || true
  [ -f "$LISTS/.exclude.resolved" ] && cp -af "$LISTS/.exclude.resolved" "$DEST_ABS/.modules.exclude.resolved" 2>/dev/null || true

  cp -af "$ANN_INIT"    "$DEST_ABS/.annot.initramfs"           2>/dev/null || true
  cp -af "$ANN_REQ"     "$DEST_ABS/.annot.require"             2>/dev/null || true
  [ -f "$ANN_EXC_RES" ] && cp -af "$ANN_EXC_RES" "$DEST_ABS/.annot.exclude.resolved" 2>/dev/null || true
  [ -f "$ANN_EXC_PAY" ] && cp -af "$ANN_EXC_PAY" "$DEST_ABS/.annot.exclude.payload"  2>/dev/null || true
fi

echo "emit-annotations: done"
