#!/usr/bin/env bash
# resolve-payload.sh — Stage-Modules Step 2
# Lint excludes, build payload union, and cascade-prune dependents (single-pass).
# BusyBox-friendly; writes artifacts under --out-dir.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: resolve-payload.sh \
  --modules-dir DIR \
  [--lint-earlyboot FILE] \
  [--lint-require  FILE] \
  [--exclude FILE] \
  --lint-script PATH_TO_lint-modlists.sh \
  --out-dir DIR \
  [--verbose] \
  [--strict-empty]        # fail if final payload list ends up empty

Writes (under --out-dir):
  .exclude.resolved         # normalized excludes accepted by linter
  .exclude.resolved.norm    # same, with suffixes unified to .ko
  .exclude.ignored          # requested excludes dropped due to conflicts
  .exclude.src.norm         # normalized original exclude list
  .payload.union            # ALL modules in this KVER
  .payload.final            # final payload after excludes & cascade
  .payload.union.norm       # normalized .ko list of union
  .payload.reverse_deps     # reverse dep edges restricted to payload
  .payload.drop_dependents  # payload modules removed due to dependency
  .reverse_deps.full        # (internal) full reverse-deps map from modules.dep

Notes:
- Inputs (earlyboot/require closures) are expected as relative paths under the modules dir.
- Exclude list may contain basenames (e.g., e1000e or e1000e.ko) or relative paths
  (e.g., kernel/drivers/.../e1000e/e1000e.ko) and compressed variants
  (.ko, .ko.{zst,xz,gz}). Suffixes are normalized internally.
- **modules.dep is required** under --modules-dir. We build a full reverse-deps map from
  modules.dep once and pass it to the linter so it can flag *indirect* conflicts where
  an excluded module would cause protected modules (earlyboot/require or their closures)
  to be lost via dependency cascade.
USAGE
}

# ---- Helpers -----------------------------------------------------------------
log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[resolve-payload] $*" >&2 || true; }
err(){ echo "[resolve-payload] ERROR: $*" >&2; exit 1; }
warn(){ echo "[resolve-payload] WARN: $*" >&2; }

# ---- Args --------------------------------------------------------------------
MODDIR= LINT_E= LINT_R= EXCL= LINT= OUTDIR=
VERBOSE=${VERBOSE:-0}; STRICT_EMPTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --modules-dir)        MODDIR=${2:?}; shift 2;;
    --lint-earlyboot)     LINT_E=${2:?}; shift 2;;
    --lint-require)       LINT_R=${2:-}; shift 2;;
    --exclude)            EXCL=${2:-};  shift 2;;
    --lint-script)        LINT=${2:?};  shift 2;;
    --out-dir)            OUTDIR=${2:?};shift 2;;
    --verbose)            VERBOSE=1; shift;;
    --strict-empty)       STRICT_EMPTY=1; shift;;
    -h|--help)            usage; exit 0;;
    *) err "Unknown arg: $1";;
  esac
done

[ -n "$MODDIR" ]  || err "missing --modules-dir"
[ -n "$LINT" ]    || err "missing --lint-script"
[ -n "$OUTDIR" ]  || err "missing --out-dir"
[ -d "$MODDIR" ]  || err "modules dir not found: $MODDIR"
mkdir -p "$OUTDIR"

# ---- Paths for outputs --------------------------------------------------------
RES_EXC="$OUTDIR/.exclude.resolved"
IGN_EXC="$OUTDIR/.exclude.ignored"
PAY_UNION="$OUTDIR/.payload.union"
PAY_FINAL="$OUTDIR/.payload.final"
PAY_DEPS="$OUTDIR/.payload.reverse_deps"
PAY_DROP="$OUTDIR/.payload.drop_dependents"
RES_EXC_NORM="$OUTDIR/.exclude.resolved.norm"
SRC_EXC_NORM="$OUTDIR/.exclude.src.norm"
REV_FULL="$OUTDIR/.reverse_deps.full"

# ---- Lint excludes ------------------------------------------------------------
: >"$RES_EXC"; : >"$RES_EXC_NORM"; : >"$IGN_EXC"; : >"$SRC_EXC_NORM"

# Build the full reverse-dependency map once (normalized .ko names)
MODDEP="$MODDIR/modules.dep"
[ -f "$MODDEP" ] || err "required file missing: $MODDEP"
: >"$REV_FULL"
log "build full reverse dependency map from modules.dep"
awk '
  function norm(p){ gsub(/\.ko\.(zst|xz|gz)$/,".ko",p); sub(/:$/,"",p); return p }
  {
    lhs=norm($1);
    for (i=2;i<=NF;i++){ dep=norm($i); if(dep!="") print dep, lhs }
  }
' "$MODDEP" | sort -u > "$REV_FULL" || true

if [ -n "${EXCL:-}" ] && [ -f "$EXCL" ]; then
  log "lint excludes (warn if they hit earlyboot/require protections)"
  "$LINT" --modules-dir "$MODDIR" \
    --exclude "$EXCL" \
    ${LINT_R:+--include-resolved "$LINT_R" --include-closure "$LINT_R"} \
    ${LINT_E:+--earlyboot-closure "$LINT_E"} \
    ${REV_FULL:+--reverse-deps "$REV_FULL"} \
    --out-exclude "$RES_EXC"
  # Report ignored excludes (requested minus resolved)
  sed -E 's/\.(ko\.(zst|xz|gz)|ko)$/.ko/' "$EXCL" | sort -u > "$SRC_EXC_NORM"
  sed -E 's/\.(ko\.(zst|xz|gz)|ko)$/.ko/' "$RES_EXC" | sort -u > "$RES_EXC_NORM"
  comm -23 "$SRC_EXC_NORM" "$RES_EXC_NORM" > "$IGN_EXC" || true
  if [ -s "$IGN_EXC" ]; then
    warn "some requested excludes were ignored due to conflicts with required/earlyboot"
  fi
fi

# ---- Build payload (single-pass) --------------------------------------------
log "compute payload: union − closure(excludes) via reverse-deps"
norm() { sed -E 's/\.(ko\.(zst|xz|gz)|ko)$/.ko/'; }
awk -F: 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); if($1!="") print $1}' "$MODDEP" \
  | norm | sort -u > "$PAY_UNION"
norm < "$PAY_UNION" | sort -u > "$OUTDIR/.payload.union.norm"
[ -s "$RES_EXC" ] && norm < "$RES_EXC" | sort -u > "$RES_EXC_NORM" || : >"$RES_EXC_NORM"

# Restrict reverse-dependency edges to the payload union:
# Pass 1 (NR==FNR): read .payload.union.norm (one module per line) into ok[]
# Pass 2: print only edges whose both endpoints are in ok[]
: >"$PAY_DEPS"
awk '
  NR==FNR { ok[$0]=1; next }     # preload union into ok[]
  ($1 in ok) && ($2 in ok)       # keep only edges fully inside union
' "$OUTDIR/.payload.union.norm" "$REV_FULL" > "$PAY_DEPS" || true

# Cascade closure: payload_final = union − closure(excludes)
: >"$PAY_DROP"
awk -v excl="$RES_EXC_NORM" \
    -v deps="$PAY_DEPS" \
    -v drop="$PAY_DROP" \
    -v final="$PAY_FINAL" \
    -v union="$OUTDIR/.payload.union.norm" '
  #
  # Inputs:
  #   excl  : newline list of accepted excludes (normalized .ko paths)
  #   deps  : reverse-deps edges restricted to union; each line "x y" means y depends on x
  #   union : newline list of ALL modules in this KVER (normalized)
  #
  # Data structures:
  #   bad[x]   = 1  if x is in the accepted excludes
  #   rev[x]   = " y1 y2 ..." space-joined list of direct dependents of x
  #   seen[x]  = 1  if x is in the reverse-closure reachable from any excluded seed
  #
  BEGIN {
    while ((getline l < excl) > 0) { bad[l]=1 } close(excl)
    while ((getline l < deps) > 0) { split(l, a)
      # a[1] = head (depended-on), a[2] = tail (dependent)
      rev[a[1]] = rev[a[1]] " " a[2]
    }
  }
  # Depth-first traversal to compute FULL reverse-closure starting at excludes.
  function dfs(x, n, arr, i) {
    if (seen[x]) return
    seen[x]=1
    n = split(rev[x], arr, " ")
    for (i=1; i<=n; i++) if (arr[i] != "") dfs(arr[i])
  }
  END {
    for (b in bad) dfs(b)
    while ((getline m < union) > 0) {
      if (!seen[m]) print m > final; else print m > drop
    }
  }
' "$OUTDIR/.payload.union.norm"

# Strictness
if [ "$STRICT_EMPTY" = 1 ] && ! [ -s "$PAY_FINAL" ]; then
  err "final payload is empty after excludes and cascade"
fi

final_count=$(wc -l < "$PAY_FINAL" 2>/dev/null || echo 0)
drop_count=$(wc -l < "$PAY_DROP" 2>/dev/null || echo 0)
log "payload_final entries: $final_count; pruned dependents: $drop_count"
echo "resolved_excludes=$RES_EXC"
echo "payload_union=$PAY_UNION"
echo "payload_final=$PAY_FINAL"
echo "payload_drop=$PAY_DROP"

# (end)
