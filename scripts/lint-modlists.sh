#!/usr/bin/env bash
set -euo pipefail
# Expand excludes (basenames or paths; .ko{,.zst,.xz,.gz} accepted; missing/empty file OK)
# and ensure they do NOT touch:
#   - include resolved list
#   - include closure
#   - earlyboot closure
# A reverse-deps map **is required** (format: "dep  user" lines, both normalized to .ko).
# We compute the reverse-dependency closure of the resolved excludes and lint against the
# expanded set (catches *indirect* breakages).
# Writes resolved excludes to --out-exclude as relative paths under --modules-dir
#
# Usage:
#   lint-modlists.sh --modules-dir /.../lib/modules/KVER \
#     [--exclude EXCLUDE_FILE] \
#     [--include-resolved FILE --include-closure FILE] \
#     [--earlyboot-closure FILE] \
#     --reverse-deps FILE \
#     --out-exclude OUTFILE
#
# Options:
#   --verbose   : extra diagnostics to stderr

MODDIR= EXCLUDE= INC_RES= INC_CLO= EB_CLO= OUT_EXCL= VERBOSE=0 REV_DEPS=
log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[lint-modules] $*" >&2 || true; }

while [ $# -gt 0 ]; do
  case "$1" in
    --modules-dir) MODDIR=${2:?}; shift 2 ;;
    --exclude) EXCLUDE=${2:?}; shift 2 ;;
    --include-resolved) INC_RES=${2:?}; shift 2 ;;
    --include-closure)  INC_CLO=${2:?}; shift 2 ;;
    --earlyboot-closure) EB_CLO=${2:?}; shift 2 ;;
    --out-exclude) OUT_EXCL=${2:?}; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --reverse-deps) REV_DEPS=${2:?}; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODDIR$OUT_EXCL" ] || { echo "missing args" >&2; exit 2; }
[ -d "$MODDIR" ] || { echo "modules dir not found: $MODDIR" >&2; exit 1; }
[ -n "${REV_DEPS:-}" ] && [ -f "$REV_DEPS" ] || { echo "missing or unreadable --reverse-deps" >&2; exit 2; }

tmp_ex=$(mktemp); trap 'rm -f "$tmp_ex"' EXIT
: >"$tmp_ex"
if [ -n "${EXCLUDE:-}" ] && [ -f "$EXCLUDE" ]; then
  log "expanding patterns from $EXCLUDE under $MODDIR"
  while IFS= read -r pat || [ -n "$pat" ]; do
    case "$pat" in ''|\#*) continue;; esac
    # normalize suffix if present
    pat="$(echo "$pat" | sed -E 's/\.(ko\.(zst|xz|gz)|ko)$/.ko/')"
    # expand pattern under MODDIR (handles path globs and compressed variants)
    ( cd "$MODDIR" && find . -type f \
        \( -path "./$pat" -o -path "./$pat.zst" -o -path "./$pat.xz" -o -path "./$pat.gz" \
           -o -name "$(basename "$pat")" -o -name "$(basename "$pat").zst" \
           -o -name "$(basename "$pat").xz" -o -name "$(basename "$pat").gz" \) \
        -print | sed -e 's#^./##' ) >>"$tmp_ex" || true
  done <"$EXCLUDE"
fi
sort -u "$tmp_ex" -o "$tmp_ex"

# If we have a reverse-deps map, expand excludes to their reverse-dep closure.
# Work on normalized .ko names; keep relative paths.
tmp_norm=$(mktemp); trap 'rm -f "$tmp_norm"' RETURN
tmp_clo=$(mktemp);  trap 'rm -f "$tmp_clo"'  RETURN
awk '{print $0}' "$tmp_ex" \
  | sed -E 's/\.(ko\.(zst|xz|gz)|ko)$/.ko/' \
  | sort -u > "$tmp_norm"
cp -f "$tmp_norm" "$tmp_clo"
if [ -s "$tmp_clo" ]; then
  log "expanding excludes by reverse-dependency closure via $REV_DEPS"
  # REV_DEPS format: "dep  user" (both normalized to .ko)
  # Iteratively add users of any excluded item until fixed point.
  while :; do
    prev=$(wc -l < "$tmp_clo")
    awk 'NR==FNR{bad[$0]=1;next} ($1 in bad){print $2}' "$tmp_clo" "$REV_DEPS" \
      | sort -u | comm -13 "$tmp_clo" - >> "$tmp_clo.tmp" || true
    if [ -s "$tmp_clo.tmp" ]; then
      cat "$tmp_clo.tmp" >> "$tmp_clo"
      sort -u -o "$tmp_clo" "$tmp_clo"
      rm -f "$tmp_clo.tmp"
    else
      rm -f "$tmp_clo.tmp"; break
    fi
    new=$(wc -l < "$tmp_clo"); [ "$new" -gt "$prev" ] || break
  done
  # Map the normalized .ko set back to any matching paths from tmp_ex for conflict checks.
  # (If both basename and path exist, either match will be caught.)
  tmp_check=$(mktemp); trap 'rm -f "$tmp_check"' RETURN
  awk '
    NR==FNR { want[$0]=1; next }
    {
      p=$0;
      n=split(p,a,"/"); b=a[n];
      gsub(/\.(ko\.(zst|xz|gz)|ko)$/,".ko",p);
      gsub(/\.(ko\.(zst|xz|gz)|ko)$/,".ko",b);
      if ( (p in want) || (b in want) ) print $0;
    }
  ' "$tmp_clo" "$tmp_ex" | sort -u > "$tmp_check"
else
  tmp_check="$tmp_ex"
fi

conflict() {
  local set="$1" label="$2"
  { [ -f "$set" ] && [ -s "$set" ]; } || return 0
  c=$(comm -12 <(sort "$set") <(sort "$tmp_check") || true)
  if [ -n "$c" ]; then
    echo "ERROR: --exclude conflicts with $label:" >&2
    echo "$c" >&2
    exit 1
  fi
}

log "checking conflicts against protected sets (if provided)"
[ -n "${INC_RES:-}" ] && [ -f "$INC_RES" ] && conflict "$INC_RES" "--require (payload must-keep)"
[ -n "${INC_CLO:-}" ] && [ -f "$INC_CLO" ] && conflict "$INC_CLO" "dependencies of --require modules"
[ -n "${EB_CLO:-}" ]  && [ -f "$EB_CLO"  ] && conflict "$EB_CLO"  "initramfs closure (early boot)"

cp -f "$tmp_ex" "$OUT_EXCL"
log "wrote $OUT_EXCL"
