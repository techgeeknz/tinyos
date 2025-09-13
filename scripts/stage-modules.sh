#!/usr/bin/env bash
# stage-modules.sh — stage kernel modules for TinyOS (initramfs + payload)
#
# ------------------------------------------------------------------------------
# Policy
#   • Modules (and dependencies) from --earlyboot are REQUIRED and go to BOTH trees:
#       - initramfs: kept UNCOMPRESSED (the archive is compressed as a whole)
#       - payload:   COMPRESSED (if supported by the kernel configuration)
#   • --require is used only to sanity-check excludes (protect important modules).
#     Payload selection is **ALL modules minus excludes** (with cascade pruning).
#     It does not force modules into initramfs.
#   • Excludes are linted against closures; conflicts are dropped with warnings.
#     Additionally, any payload module depending on an excluded module is pruned
#     (with warnings) via reverse-dependency cascade.
#   • Payload compression: pick best supported by kernel .config:
#       zstd → xz → gzip → none. If .config missing, WARN and use none.
#
# Step plan
#   1) Compute closures (earlyboot, require)
#   2) Resolve excludes + build/cascade payload (delegated to resolve-payload.sh)
#   3) Stage files into initramfs and payload
#   4) Copy metadata + run depmod in staging
#   5) Decide payload compression tool (resolve 'auto')
#   6) Normalize & compress staged trees
#   7) Emit annotated, reusable lists (delegated to emit-annotations.sh)
#
# All work happens inside --dest (staging). Source modules tree is read-only.
# ------------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
STAGED_KVER="$SCRIPT_DIR/staged-kver.sh"
DEPMOD_SAFE="$SCRIPT_DIR/depmod-safe.sh"

usage() {
  cat <<'USAGE'
Usage: stage-modules.sh \
  --modules-dir DIR             # path to lib/modules/<KVER> (or lib/modules) \
  [--earlyboot FILE]            # seed list for initramfs (optional) \
  [--require FILE]              # seed list for payload sanity-checks (optional) \
  [--exclude FILE]              # requested excludes (basenames/paths; compressed ok) \
  [--config-dir DIR]            # directory to search for module seed lists (optional) \
  [--lists-dir DIR]             # where to write list artifacts (default: $DEST/.lists) \
  [--graph-dir DIR]             # where to write graph artifacts (default: $DEST/.modgraph) \
  --dest DIR                    # staging root (required) \
  [--compress auto|zstd|xz|gzip|none]    # payload compression policy (default: auto) \
  [--kernel-config FILE]        # kernel .config to infer decompressors (default: linux/.config) \
  [--stamp-initramfs FILE]      # touch after initramfs is fully staged+normalized \
  [--stamp-payload FILE]        # touch after payload is fully staged+compressed \
  [--verbose] [--strict-empty]  # pass through to resolve-payload \
  [--no-annot-copies]           # pass through to emit-annotations (skip convenience copies) \
  [-h|--help]

Artifacts in $DEST:
  .modgraph/  .lists/                       # debug logs and lists
  initramfs/lib/modules/<KVER>  (uncompressed modules)
  payload/lib/modules/<KVER>    (per --compress)
  .modules.*  .annot.*                     # convenience copies
USAGE
}

log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[stage-modules] $*" >&2 || true; }
err(){ echo "[stage-modules] ERROR: $*" >&2; exit 1; }

# ---- Args --------------------------------------------------------------------
MODULES_DIR=""; CONFIG_DIR="${PROJECT_ROOT}/config"
EARLYBOOT_LIST=""; REQUIRE_LIST=""; EXCLUDE_LIST=""
DEST=""; VERBOSE=${VERBOSE:-0}
LISTS_DIR=""; GRAPH_DIR=""
COMPRESS_MODE="auto"; KERNEL_CONFIG=""; STRICT_EMPTY=0; NO_ANNOT_COPIES=0
STAMP_INITRAMFS=""; STAMP_PAYLOAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --modules-dir)     MODULES_DIR=${2:?}; shift 2;;
    --earlyboot)       EARLYBOOT_LIST=${2:?}; shift 2;;
    --require)         REQUIRE_LIST=${2:-}; shift 2;;
    --exclude)         EXCLUDE_LIST=${2:-}; shift 2;;
    --config-dir)      CONFIG_DIR=${2:?}; shift 2;;
    --lists-dir)       LISTS_DIR=${2:?}; shift 2;;
    --graph-dir)       GRAPH_DIR=${2:?}; shift 2;;
    --dest)            DEST=${2:?}; shift 2;;
    --compress)        COMPRESS_MODE=${2:?}; shift 2;;
    --kernel-config)   KERNEL_CONFIG=${2:?}; shift 2;;
    --stamp-initramfs) STAMP_INITRAMFS=${2:?}; shift 2;;
    --stamp-payload)   STAMP_PAYLOAD=${2:?}; shift 2;;
    --verbose)         VERBOSE=1; shift;;
    --strict-empty)    STRICT_EMPTY=1; shift;;
    --no-annot-copies) NO_ANNOT_COPIES=1; shift;;
    -h|--help)         usage; exit 0;;
    *) err "Unknown arg: $1";;
  esac
done
[ -n "$EARLYBOOT_LIST" ] || EARLYBOOT_LIST="$CONFIG_DIR/modules.earlyboot"
[ -n "$REQUIRE_LIST" ]   || REQUIRE_LIST="$CONFIG_DIR/modules.require"
[ -n "$EXCLUDE_LIST" ]   || EXCLUDE_LIST="$CONFIG_DIR/modules.exclude"

[ -n "$DEST" ]           || err "--dest is required"
# Validate compress mode early
case "$COMPRESS_MODE" in
  auto|zstd|xz|gzip|none) ;;
  *) echo "[stage-modules] WARN: unknown --compress='$COMPRESS_MODE'; using 'auto'" >&2; COMPRESS_MODE="auto" ;;
esac

# Normalize MODULES_DIR → .../lib/modules/<KVER>, using the staged tree as truth.
[ -n "$MODULES_DIR" ] || err "--modules-dir is required"
if [ -d "$MODULES_DIR/kernel" ]; then
  # caller passed .../lib/modules/<KVER>
  KVER="$(basename "$MODULES_DIR")"
  MODULES_ROOT="$(cd -- "$MODULES_DIR/.." && pwd)"
elif [ -d "$MODULES_DIR" ]; then
  [ -x "$STAGED_KVER" ] || err "missing helper: $STAGED_KVER"
  KVER="$("$STAGED_KVER" --modules-root "$MODULES_DIR" --one ${VERBOSE:+--verbose})"
  MODULES_DIR="$MODULES_DIR/$KVER"
else
  err "--modules-dir must be '.../lib/modules' or '.../lib/modules/<KVER>' (got: $MODULES_DIR)"
fi
[ -d "$MODULES_DIR/kernel" ] || err "modules dir not found: $MODULES_DIR (did you run modules_install?)"

log "KVER=$KVER; modules=$MODULES_DIR"

# Prepare dirs
DEST_ABS="$(mkdir -p "$DEST" && cd "$DEST" && pwd)"
INIT_DST="$DEST_ABS/initramfs/lib/modules/$KVER"
PAY_DST="$DEST_ABS/payload/lib/modules/$KVER"
ART_GRAPH="${GRAPH_DIR:-$DEST_ABS/.modgraph}"
ART_LISTS="${LISTS_DIR:-$DEST_ABS/.lists}"
mkdir -p "$INIT_DST" "$PAY_DST" "$ART_GRAPH" "$ART_LISTS"

# Helper scripts
MOD_GRAPH="$SCRIPT_DIR/module-graph.sh"
LINT_LISTS="$SCRIPT_DIR/lint-modlists.sh"
COMPRESSOR="$SCRIPT_DIR/compress-modules.sh"
RESOLVE_PAYLOAD="$SCRIPT_DIR/resolve-payload.sh"
EMIT_ANNOT="$SCRIPT_DIR/emit-annotations.sh"
[ -x "$MOD_GRAPH" ]       || err "missing helper: $MOD_GRAPH"
[ -x "$LINT_LISTS" ]      || err "missing helper: $LINT_LISTS"
[ -x "$COMPRESSOR" ]      || err "missing helper: $COMPRESSOR"
[ -x "$RESOLVE_PAYLOAD" ] || err "missing helper: $RESOLVE_PAYLOAD"
[ -x "$EMIT_ANNOT" ]      || err "missing helper: $EMIT_ANNOT"

# 1) Compute closures
log "graph earlyboot → label=initramfs"
"$MOD_GRAPH" --kver "$KVER" --modules-dir "$MODULES_DIR" \
  --seed "$EARLYBOOT_LIST" --label initramfs --out-dir "$ART_GRAPH"
log "graph require → label=require"
"$MOD_GRAPH" --kver "$KVER" --modules-dir "$MODULES_DIR" \
  --seed "$REQUIRE_LIST" --label require --out-dir "$ART_GRAPH"

# 2) Resolve excludes + build/cascade payload (delegated)
[ $VERBOSE -gt 0 ] && RP_VERBOSE=--verbose || RP_VERBOSE=
[ $STRICT_EMPTY -gt 0 ] && RP_STRICT_EMPTY=--strict-empty || RP_STRICT_EMPTY=
log "resolve payload (lint, ALL-minus-excludes, cascade)"
RP_EXCL=()
[ -f "$EXCLUDE_LIST" ] && RP_EXCL=( --exclude "$EXCLUDE_LIST" )
"$RESOLVE_PAYLOAD" \
  --modules-dir "$MODULES_DIR" \
  --lint-earlyboot "$ART_GRAPH/.initramfs.closure" \
  --lint-require "$ART_GRAPH/.require.closure" \
  "${RP_EXCL[@]}" \
  --lint-script "$LINT_LISTS" \
  --out-dir "$ART_LISTS" \
  $RP_VERBOSE \
  $RP_STRICT_EMPTY \
  | sed -n 's/^/[resolve] /p'

RESOLVED_EXC="$ART_LISTS/.exclude.resolved"

# Lists produced by helpers:
# - module-graph.sh   → $ART_GRAPH/.initramfs.modules   (normalized)
# - resolve-payload.sh→ $ART_LISTS/.payload.final       (normalized)
INIT_LIST="$ART_GRAPH/.initramfs.modules"
PAY_LIST="$ART_LISTS/.payload.final"

# Helper: copy_list (used in step 3)
# BusyBox-friendly; preserves compression suffix when the source exists as .ko.zst/.xz/.gz
copy_list(){
  local list="$1" src="$2" dst="$3" copied=0 missing=0
  while IFS= read -r rel || [ -n "$rel" ]; do
    [ -n "$rel" ] || continue
    local s="$src/$rel"
    if [ ! -e "$s" ]; then
      for ext in zst xz gz; do [ -e "$s.$ext" ] && { s="$s.$ext"; break; }; done
    fi
    if [ ! -e "$s" ]; then
      echo "[stage-modules] WARN: missing module: $rel" >&2; missing=$((missing+1)); continue
    fi
    mkdir -p "$dst/$(dirname "$rel")"
    cp -a "$s" "$dst/$rel${s#${src}/$rel}"
    copied=$((copied+1))
    log "copied: $rel"
  done <"$list"
  echo "$copied $missing"
}

# 3) Stage files into initramfs and payload
read COPIED_INIT MISSING_INIT < <(copy_list "$INIT_LIST" "$MODULES_DIR" "$INIT_DST")
read COPIED_PAY  MISSING_PAY  < <(copy_list "$PAY_LIST"  "$MODULES_DIR" "$PAY_DST")
log "initramfs copied=$COPIED_INIT missing=$MISSING_INIT; payload copied=$COPIED_PAY missing=$MISSING_PAY"

# Ensure skeleton kernel/ dirs exist, so depmod-safe and firmware collection won't choke
mkdir -p "$INIT_DST/kernel" "$PAY_DST/kernel"

# 4) Copy metadata + depmod
for KROOT in "$INIT_DST" "$PAY_DST"; do
  for f in modules.order modules.builtin modules.builtin.modinfo modules.softdep \
           modules.symbols modules.symbols.bin modules.alias modules.alias.bin \
           modules.devname modules.dep modules.dep.bin; do
    [ -f "$MODULES_DIR/$f" ] && cp -a "$MODULES_DIR/$f" "$KROOT/$f" || true
  done
  # Use robust helper if available; falls back to plain depmod.
  if [ -x "$DEPMOD_SAFE" ]; then
    VERBOSE=$VERBOSE "$DEPMOD_SAFE" --modules-dir "${KROOT%/lib/modules/$KVER}/lib/modules/$KVER" || true
  elif command -v depmod >/dev/null 2>&1; then
    depmod -b "${KROOT%/lib/modules/$KVER}" "$KVER" || true
  fi
done

# 5) Decide payload compression tool (resolve 'auto' via kernel config)
COMP_TOOL="$COMPRESS_MODE"
if [ "$COMP_TOOL" = "auto" ]; then
  CFG="${KERNEL_CONFIG:-$PROJECT_ROOT/linux/.config}"
  if [ -f "$CFG" ]; then
    if   grep -q '^CONFIG_MODULE_COMPRESS_ZSTD=y' "$CFG" 2>/dev/null; then COMP_TOOL="zstd"
    elif grep -q '^CONFIG_MODULE_COMPRESS_XZ=y'   "$CFG" 2>/dev/null; then COMP_TOOL="xz"
    elif grep -q '^CONFIG_MODULE_COMPRESS_GZIP=y' "$CFG" 2>/dev/null; then COMP_TOOL="gzip"
    else COMP_TOOL="none"; fi
  else
    echo "[stage-modules] WARN: kernel config not found: $CFG; defaulting payload compression to 'none'" >&2
    COMP_TOOL="none"
  fi
fi
log "payload compressor: $COMP_TOOL"

# 6) Normalize & compress staged trees
"$COMPRESSOR" --modules-dir "$INIT_DST" --tool none --keep-list "$ART_GRAPH/.initramfs.modules" || true
[ -n "$STAMP_INITRAMFS" ] && { mkdir -p "$(dirname -- "$STAMP_INITRAMFS")"; : >"$STAMP_INITRAMFS"; }

"$COMPRESSOR" --modules-dir "$PAY_DST"  --tool "$COMP_TOOL" --exclude-list "$RESOLVED_EXC" || true
[ -n "$STAMP_PAYLOAD" ] && { mkdir -p "$(dirname -- "$STAMP_PAYLOAD")"; : >"$STAMP_PAYLOAD"; }

# 7) Emit annotated, reusable lists (delegated)
"$EMIT_ANNOT" --graph-dir "$ART_GRAPH" --lists-dir "$ART_LISTS" --dest "$DEST_ABS" ${VERBOSE:+--verbose} ${NO_ANNOT_COPIES:+--no-copies} | sed -n 's/^/[annot] /p'

echo "stage-modules.sh: completed successfully (compress=$COMP_TOOL)"
