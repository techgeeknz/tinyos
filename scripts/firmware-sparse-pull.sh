#!/usr/bin/env bash
# firmware-sparse-pull.sh — best-effort sparse fetch of required firmware paths
# REQUIRES Git sparse-checkout **cone mode**. If cone mode is not supported, abort
# and instruct the user to run a full clone (`make firmware-full`) instead.
# Respects the environment variable GIT (defaults to `git`).
#
# Usage:
#   firmware-sparse-pull.sh --repo <dir> \
#     [--from-map <fw→mods.map>]... \
#     [--from-missing <missing>]... \
#     [--verbose]
# Notes:
#   * Repo must have been prepared via `make firmware-init` (remote=origin set).
#   * Accepts multiple map/missing files; ignores absent/empty ones.
#   * Extracts relative firmware paths (e.g. "iwlwifi-8000C-36.ucode", "radeon/X.bin(.xz)").
#   * Sources of truth:
#       - maps: TSV "firmware_path<TAB>module.ko"
#       - missing: single-column list of firmware paths with "# <module.ko>" comment headers (ignored here)
#   * Adds paths to sparse-checkout and fetches only what’s needed.
set -euo pipefail

REPO=""
GIT_CMD="${GIT:-git}"

MAPS=()
MISS=()
VERBOSE=0

log(){ [ "$VERBOSE" -gt 0 ] && echo "[$(basename "$0")] $*" || true; }

die(){ echo "[$(basename "$0")] ERROR: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=$2; shift 2;;
    --from-map) MAPS+=("$2"); shift 2;;
    --from-missing) MISS+=("$2"); shift 2;;
    --verbose) VERBOSE=1; shift;;
    *) die "unknown arg: $1";;
  esac
done

[ -n "$REPO" ] || die "--repo required"
[ -d "$REPO/.git" ] || die "repo not initialized: $REPO (run: make firmware-init)"

# --- capability probes -------------------------------------------------------
have_sparse_subcmd=0
if "$GIT_CMD" -C "$REPO" sparse-checkout -h >/dev/null 2>&1; then
  have_sparse_subcmd=1
fi

have_cone=0
if [ $have_sparse_subcmd -eq 1 ] && "$GIT_CMD" -C "$REPO" sparse-checkout init -h 2>&1 | grep -q -- '--cone'; then
  have_cone=1
fi

if [ $have_cone -ne 1 ]; then
  cat >&2 <<EOF
[$(basename "$0")] ERROR: Your Git does not support sparse-checkout cone mode.
  - Either upgrade Git (recommended), or
  - run: make firmware-full      # full (non-sparse) clone of linux-firmware
EOF
  exit 3
fi

# Refuse to operate on a non-sparse/full repo (avoid mixing models).
if ! "$GIT_CMD" -C "$REPO" config --bool core.sparseCheckout | grep -q '^true$'; then
  die "repository at $REPO is not a sparse-checkout; run: make firmware-pull"
fi

# Collect relpaths from maps (first column is firmware path or absolute; prefer rel)
tmp_paths=$(mktemp)
trap 'rm -f "$tmp_paths"' EXIT

emit_rel() {
  # normalize to relative path under linux-firmware
  # Accept:
  #   - "foo/bar.bin", or "foo/bar.bin.{xz,zst,gz}"
  #   - optional "<abs>\\t<rel>" (maps)
  #   - ignore comment headers: lines starting with "#"
  awk -F'\t' '
    {
      line = $0;
      sub(/\r$/, "", line);            # tolerate CRFL
      if (line ~ /^#/) next;           # drop comments (headers in .missing)
      gsub(/^[[:space:]]+/, "", line); # strip leading blanks
      gsub(/[[:space:]]+$/, "", line); # strip trailing blanks
      if (line == "") next;            # drop blank lines
      print line;
    }
  '
}

for f in "${MAPS[@]}"; do
  [ -s "$f" ] || continue
  log "consume map: $f"
  cut -f1 "$f" 2>/dev/null | emit_rel >>"$tmp_paths" || true
done

for f in "${MISS[@]}"; do
  [ -s "$f" ] || continue
  log "consume missing: $f"
  emit_rel  <"$f" >>"$tmp_paths" || true
done

# Unique, non-empty
sort -u "$tmp_paths" | sed -n '/[^[:space:]]/p' > "$tmp_paths.sorted" || true
mv -f "$tmp_paths.sorted" "$tmp_paths" 2>/dev/null || :  # tolerate truly empty case

if [ ! -s "$tmp_paths" ]; then
  log "no firmware paths requested; nothing to fetch"
  exit 0
fi

# Ensure sparse-checkout is initialised in cone mode, then add paths
if [ $have_cone -eq 1 ]; then
  # Repo must already be sparse (firmware-init enforces cone). Append/update paths.
  "$GIT_CMD" -C "$REPO" sparse-checkout set --stdin <"$tmp_paths"
fi

# Fetch (shallow) and checkout only requested paths
log "fetch (depth=1) and checkout main"
"$GIT_CMD" -C "$REPO" fetch --depth=1 origin main
# Ensure we stay branch-aware (no detached HEAD)
"$GIT_CMD" -C "$REPO" switch -q -c main --track origin/main 2>/dev/null || "$GIT_CMD" -C "$REPO" switch -q main
"$GIT_CMD" -C "$REPO" reset --hard -q origin/main

log "done"
