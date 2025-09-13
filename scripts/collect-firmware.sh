#!/usr/bin/env bash
set -euo pipefail
# collect-firmware.sh — stage required firmware for a set of staged modules + emit maps
#
# Goal: Given a staged modules tree, locate the firmware each module declares
# (via `modinfo -F firmware`) inside a firmware source tree, and copy it into
# a destination directory. No policy beyond optional size limits and clean artifacts.
#
# Usage:
#   collect-firmware.sh \
#     --modules-dir  /path/to/lib/modules/<KVER> \
#     --firmware-src /path/to/linux-firmware-or-/lib/firmware \
#     --dest         /path/to/output \
#     [--modules-list FILE]          # limit scan to modules listed (rel paths) \
#     [--max-file-bytes N]           # (optional) per-file limit; default: ∞ \
#     [--max-total-bytes N]          # (optional) total limit over unique files; default: ∞ \
#     [--fail-on-file-limit]         # make per-file limit fatal (otherwise warn) \
#     [--out-list FILE]              # default: $DEST/.firmware.list \
#     [--out-missing FILE]           # default: $DEST/.firmware.missing \
#     [--out-heavy FILE]             # default: $DEST/.firmware.heavy \
#     [--out-map-fw FILE]            # default: $DEST/.firmware.map (firmware → modules, TSV) \
#     [--out-map-mod FILE]           # default: $DEST/.module-firmware.map (module → firmware, TSV) \
#                                    # both maps are deduped and sorted
#     [--out-summary FILE]           # default: $DEST/.firmware.summary \
#     [--dry-run] [--verbose]
#
# Notes:
# - We do not compress firmware; we copy what upstream provides (raw or .xz/.zst/.gz).
# - Selection policy (which modules exist) lives upstream; this script only follows lists.
# - The script uses bash associative arrays (declare -A), requiring bash ≥4.

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
STAGED_KVER="$SCRIPT_DIR/staged-kver.sh"
log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[collect-firmware] $*" >&2 || true; }
err(){ echo "[collect-firmware] ERROR: $*" >&2; exit 2; }

TAB=$'\t'

# ------------------------------ args ----------------------------------------
MODULES_DIR= FWROOT= DEST=
MODULES_LIST=
MAX_FILE_BYTES=""
MAX_TOTAL_BYTES=""
FAIL_ON_FILE_LIMIT=0
DRY_RUN=0
VERBOSE=0

OUT_LIST=""
OUT_MISSING=""
OUT_HEAVY=""
OUT_SUMMARY=""
OUT_MAP_FW=""
OUT_MAP_MOD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --modules-dir)      MODULES_DIR=${2:?}; shift 2 ;;
    --firmware-src)     FWROOT=${2:?}; shift 2 ;;
    --dest)             DEST=${2:?}; shift 2 ;;
    --modules-list)     MODULES_LIST=${2:?}; shift 2 ;;
    --max-file-bytes)   MAX_FILE_BYTES=${2:?}; shift 2 ;;
    --max-total-bytes)  MAX_TOTAL_BYTES=${2:?}; shift 2 ;;
    --fail-on-file-limit) FAIL_ON_FILE_LIMIT=1; shift ;;
    --out-list)         OUT_LIST=${2:?}; shift 2 ;;
    --out-missing)      OUT_MISSING=${2:?}; shift 2 ;;
    --out-heavy)        OUT_HEAVY=${2:?}; shift 2 ;;
    --out-map-fw)       OUT_MAP_FW=${2:?}; shift 2 ;;
    --out-map-mod)      OUT_MAP_MOD=${2:?}; shift 2 ;;
    --out-summary)      OUT_SUMMARY=${2:?}; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --verbose)          VERBOSE=1; shift ;;
    -h|--help)
      sed -n '1,120p' "$0" | sed -n '1,80p'
      exit 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$MODULES_DIR$FWROOT$DEST" ] || { echo "Missing required args" >&2; exit 2; }

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

log "FWROOT='$FWROOT' DEST='$DEST' MODDIR='$MODULES_DIR'"

# default artifact paths if not provided
: "${OUT_LIST:=$DEST/.firmware.list}"
: "${OUT_MISSING:=$DEST/.firmware.missing}"
: "${OUT_HEAVY:=$DEST/.firmware.heavy}"
: "${OUT_SUMMARY:=$DEST/.firmware.summary}"
: "${OUT_MAP_FW:=$DEST/.firmware.map}"
: "${OUT_MAP_MOD:=$DEST/.module-firmware.map}"

mkdir -p "$DEST"
: >"$OUT_LIST"; : >"$OUT_MISSING"; : >"$OUT_HEAVY"
: >"$OUT_SUMMARY"; : >"$OUT_MAP_FW"; : >"$OUT_MAP_MOD"

# If firmware source dir is missing, still leave well-formed empty artifacts.
[ -d "$FWROOT" ] || {
  echo "WARN: firmware source not found: $FWROOT" >&2
  printf 'copied=%d missing=%d heavy=%d total=%dB dest=%s\n' 0 0 0 0 "$DEST" >"$OUT_SUMMARY"
  exit 0
}

real() {
  if command -v readlink >/dev/null 2>&1; then readlink -f -- "$1" 2>/dev/null || true; return; fi
  if command -v realpath >/dev/null 2>&1; then realpath -- "$1"; return; fi
  echo "$1"
}

append_map_fw() {
  # firmware → module (TSV). Defer dedupe to a final sort -u.
  # $1 = firmware (relative path as staged), $2 = module basename
  printf '%s\t%s\n' "$1" "$2" >>"$OUT_MAP_FW"
}
append_map_mod() {
  # module → firmware (TSV)
  # $1 = module basename, $2 = firmware (relative path as staged)
  printf '%s\t%s\n' "$1" "$2" >>"$OUT_MAP_MOD"
}

locate_fw() {
  local name="$1" cand rel base
  rel="$name"
  for cand in "$FWROOT/$rel" "$FWROOT/$rel.xz" "$FWROOT/$rel.zst" "$FWROOT/$rel.gz"; do
    [ -f "$cand" ] && { printf '%s'"$TAB"'%s\n' "$(real "$cand")" "$rel"; return 0; }
  done
  base="$(basename -- "$rel")"
  cand="$(find "$FWROOT" -type f -name "$base" -print -quit 2>/dev/null || true)"
  [ -n "$cand" ] && { printf '%s'"$TAB"'%s\n' "$(real "$cand")" "$base"; return 0; }
  return 1
}

install_fw() {
  local abs="$1" rel="$2"
  case "$rel" in
    */..|../*|*/../* ) echo "ERROR: refusing suspicious firmware path: $rel" >&2; return 1;;
  esac
  if [ "$DRY_RUN" = 1 ]; then echo "COPY $rel"; return 0; fi
  install -D -m 0644 "$abs" "$DEST/$rel"
}

modules_iter() {
  if [ -n "$MODULES_LIST" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      case "$rel" in \#* ) continue;; esac
      printf '%s\n' "$MODULES_DIR/$rel"
    done <"$MODULES_LIST"
  else
    find "$MODULES_DIR" -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) | sort
  fi
}

# ------------------------------ scan & copy ---------------------------------

copied=0; missed=0; heavy=0
TOTAL_BYTES=0
declare -A SEEN_FW=()

# Track whether we’ve emitted a section header for a module in each file
HDR_LIST_EMITTED=""
HDR_MISS_EMITTED=""
# For compact WARNs
declare -A MISSES_PER_MOD=()   # module.ko → count

if ! command -v modinfo >/dev/null 2>&1; then
  echo "WARN: 'modinfo' not found; skipping firmware collection" >&2
  printf 'copied=%d missing=%d heavy=%d total=%dB dest=%s\n' 0 0 0 0 "$DEST" >"$OUT_SUMMARY"
  exit 0
fi

while IFS= read -r ko; do
  [ -n "$ko" ] || continue
  modbase="$(basename -- "$ko")"
  while IFS= read -r fw; do
    [ -n "$fw" ] || continue
    if out=$(locate_fw "$fw"); then
      abs="${out%%"$TAB"*}"; rel="${out#*"$TAB"}"
      size=$(stat -c '%s' "$abs" 2>/dev/null || echo 0)
      if [ -n "$MAX_FILE_BYTES" ] && [ "$size" -ge "$MAX_FILE_BYTES" ]; then
        printf '%s\n' "$rel" >>"$OUT_HEAVY"; heavy=$((heavy+1))
        if [ "$FAIL_ON_FILE_LIMIT" = 1 ]; then
          echo "ERROR: firmware over per-file limit: $rel ($size bytes)" >&2; exit 99
        else
          echo "WARN: firmware over per-file limit: $rel ($size bytes)" >&2
        fi
      fi
      if [ -z "${SEEN_FW[$rel]+x}" ]; then
        SEEN_FW[$rel]=1
        TOTAL_BYTES=$((TOTAL_BYTES + size))
      fi
      # Emit header in .list on first hit for this module
      if [ "$HDR_LIST_EMITTED" != "$modbase" ]; then
        [ -z "$HDR_LIST_EMITTED" ] || printf '\n' >>"$OUT_LIST"
        printf '# %s\n' "$modbase" >>"$OUT_LIST"
        HDR_LIST_EMITTED="$modbase"
      fi
      printf ' %s\n' "$rel" >>"$OUT_LIST"
      log "copy: $rel ($size bytes)"
      install_fw "$abs" "$rel"
      copied=$((copied+1))

      # Maps (only for found firmware)
      append_map_fw "$rel" "$modbase"
      append_map_mod "$modbase" "$rel"
    else
      # Emit header in .missing on first miss for this module
      if [ "$HDR_MISS_EMITTED" != "$modbase" ]; then
        [ -z "$HDR_MISS_EMITTED" ] || printf '\n' >>"$OUT_MISSING"
        printf '# %s\n' "$modbase" >>"$OUT_MISSING"
        HDR_MISS_EMITTED="$modbase"
      fi
      printf ' %s\n' "$fw" >>"$OUT_MISSING"
      missed=$((missed+1))
      # Defer spam: count per-module and summarize after the scan
      MISSES_PER_MOD["$modbase"]=$(( ${MISSES_PER_MOD["$modbase"]:-0} + 1 ))
    fi
  done < <(modinfo -F firmware "$ko" 2>/dev/null | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' | grep -v '^$' | sort -u)
done < <(modules_iter)

# Preserve grouping in .list / .missing; still sort maps + heavy
for f in "$OUT_HEAVY" "$OUT_MAP_FW" "$OUT_MAP_MOD"; do
  [ -f "$f" ] && sort -u "$f" -o "$f" || true
done

# Summarize missing per module (no spam), then one final pointer
if [ "$missed" -gt 0 ]; then
  # Stable order: by module name
  for m in $(printf '%s\n' "${!MISSES_PER_MOD[@]}" | LC_ALL=C sort); do
    n=${MISSES_PER_MOD["$m"]}
    echo "WARN: $n firmware entr$( [ $n -eq 1 ] && echo 'y' || echo 'ies' ) missing for module $m" >&2
  done
  echo "WARN: missing firmware detected; for details, see: $OUT_MISSING" >&2
fi

if [ -n "$MAX_TOTAL_BYTES" ] && [ "$TOTAL_BYTES" -gt "$MAX_TOTAL_BYTES" ]; then
  printf 'ERROR: total firmware size %d bytes exceeds max-total-bytes=%d\n' "$TOTAL_BYTES" "$MAX_TOTAL_BYTES" >&2
  echo "Hint: reduce modules in this invocation or raise the limit." >&2
  exit 98
fi

printf 'copied=%d missing=%d heavy=%d total=%dB dest=%s\n' "$copied" "$missed" "$heavy" "$TOTAL_BYTES" "$DEST" >"$OUT_SUMMARY"

# Done
