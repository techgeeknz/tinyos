#!/usr/bin/env bash
set -euo pipefail
# Compute transitive module closures from modules.dep
# Emits files into --out-dir with a prefix based on --label:
#   .<label>.builtins   # modules skipped because built into kernel
#   .<label>.resolved   # resolved seed modules
#   .<label>.closure    # full closure of dependencies
#   .<label>.added_deps # transitive dependencies discovered
#   .<label>.missing    # missing modules encountered
#   .<label>.modules    # normalized .ko list (uncompressed names)
#
# Usage:
#   module-graph.sh --kver KVER --modules-dir /.../lib/modules/KVER \
#                   --seed FILE --label LABEL --out-dir OUTDIR

LC_ALL=C; export LC_ALL
KVER= MODDIR= SEED= LABEL= OUTDIR= VERBOSE=0
log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[modules-graph] $*" >&2 || true; }

while [ $# -gt 0 ]; do
  case "$1" in
    --kver) KVER=${2:?}; shift 2 ;;
    --modules-dir) MODDIR=${2:?}; shift 2 ;;
    --seed) SEED=${2:?}; shift 2 ;;
    --label) LABEL=${2:?}; shift 2 ;;
    --out-dir) OUTDIR=${2:?}; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$KVER$MODDIR$SEED$LABEL$OUTDIR" ] || { echo "missing args" >&2; exit 2; }
[ -d "$MODDIR" ] || { echo "modules dir not found: $MODDIR" >&2; exit 1; }
DEP="$MODDIR/modules.dep"
[ -f "$DEP" ] || { echo "modules.dep not found at $DEP" >&2; exit 1; }
mkdir -p "$OUTDIR"
log "KVER=$KVER, MODDIR=$MODDIR, LABEL=$LABEL"

prefix="$LABEL"
out_bui="$OUTDIR/.$prefix.builtins"
out_res="$OUTDIR/.$prefix.resolved"
out_clo="$OUTDIR/.$prefix.closure"
out_add="$OUTDIR/.$prefix.added_deps"
out_mis="$OUTDIR/.$prefix.missing"
out_mods="$OUTDIR/.$prefix.modules"

# temp files
tmp_seed=$(mktemp); trap 'rm -f "$tmp_seed"' EXIT

# resolve a requested item (accepts bare name or path) to relative path under MODDIR
resolve_rel() {
  local req="$1"
  [[ $req == *.ko* ]] || req="${req%.ko}.ko"
  local base=$(basename "$req")
  local f
  # search builtins
  if grep -F "${base%.ko*}.ko" "$MODDIR/modules.builtin" >> "$out_bui"; then
    echo "[modules-graph] skipping builtin: ${base%.ko*}" >&2
    return 0
  fi
  # search by path
  for f in "$MODDIR/$req" "$MODDIR/${req}.zst" "$MODDIR/${req}.xz" "$MODDIR/${req}.gz"; do
    [ -f "$f" ] && { echo "${f#"$MODDIR"/}"; return 0; }
  done
  # search by basename
  f=$(cd "$MODDIR" && find . -type f \( -name "$base" -o -name "${base}.zst" -o -name "${base}.xz" -o -name "${base}.gz" \) -print -quit | sed -e 's#^./##')
  [ -n "$f" ] && { echo "$f"; return 0; }
  return 1
}

# load seed (comments allowed). Missing/empty seed file is OK.
: >"$tmp_seed"; : >"$out_mis"
if [ -f "$SEED" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    if rel=$(resolve_rel "$line"); then
      if [ -n "$rel" ]; then
        log "seed: $line -> $rel"
        printf '%s\n' "$rel" >>"$tmp_seed"
      fi
    else
      echo "[modules-graph] WARN: seed not found: $line" >&2
      printf '%s\n' "$line" >>"$out_mis"
    fi
  done <"$SEED"
fi
sort -u "$tmp_seed" -o "$tmp_seed"
cp -f "$tmp_seed" "$out_res"

# BFS closure
: >"$out_clo"; : >"$out_add"; : >"$out_mods"
seen=$(mktemp); trap 'rm -f "$tmp_seed" "$seen"' EXIT
touch "$seen"

while IFS= read -r rel; do
  queue=("$rel")
  while [ ${#queue[@]} -gt 0 ]; do
    cur=${queue[0]}; queue=(${queue[@]:1})
    # de-dup
    grep -qx -- "$cur" "$seen" && continue
    printf '%s\n' "$cur" >>"$seen"
    printf '%s\n' "$cur" >>"$out_clo"
    base="${cur%.zst}"; base="${base%.xz}"; base="${base%.gz}"
    [[ $base == *.ko ]] || base="${base%.ko}.ko"
    printf '%s\n' "$base" >>"$out_mods"
    # deps line
    line=$(grep -F -m1 "^$cur:" "$DEP" || true)
    if [ -n "$line" ]; then
      deps=${line#*: }
      for d in $deps; do
        case "$d" in */*) d_rel="$d" ;; *) d_rel="$(dirname "$cur")/$d" ;; esac
        d_rel=${d_rel#./}
        queue+=("$d_rel")
        printf '%s <- required by %s\n' "$d_rel" "$cur" >>"$out_add"
      done
    else
      # Missing line in modules.dep: if file doesn't exist in any form, mark missing
      if [ ! -e "$MODDIR/$cur" ] && [ ! -e "$MODDIR/$cur.gz" ] && [ ! -e "$MODDIR/$cur.xz" ] && [ ! -e "$MODDIR/$cur.zst" ]; then
        printf '%s <- required by %s\n' "$cur" "$rel" >>"$out_mis"
      fi
    fi
  done
done <"$tmp_seed"

sort -u "$out_clo" -o "$out_clo"
sort -u "$out_mods" -o "$out_mods"
[ -s "$out_add" ] && sort -u "$out_add" -o "$out_add" || true
[ -s "$out_mis" ] && sort -u "$out_mis" -o "$out_mis" || true
[ -s "$out_bui" ] && sort -u "$out_bui" -o "$out_bui" || true
log "closure entries: $(wc -l <"$out_clo" 2>/dev/null || echo 0)"
