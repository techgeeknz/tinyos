#!/usr/bin/env bash
# tinyos-conf-to-mk.sh — sanitize tinyos.conf into Make-safe assignments.
# Grammar (input): each non-blank line is either a full-line comment (#...) or KEY=VALUE.
# No quoting/escapes in input; leading/trailing spaces around KEY/VALUE are trimmed.
# Output:
#   • Simple values (no # or \):  KEY := VALUE        (with $ doubled)
#   • Tricky values (contains # or \): as a multi-line make variable:
#         define KEY\n<value-with-$$>\nendef
#     (keeps # literal, avoids line-continuation backslash hazards)
#   • Empty values are ignored (don’t override Make’s defaults with empty)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TINYOS_CONF_SH="$SCRIPT_DIR/tinyos-conf.sh"

usage() {
  cat <<'EOF'
Usage: tinyos-conf-to-mk.sh --in <tinyos.conf> --out <sanitized.mk>
EOF
}

IN= OUT=
while [ $# -gt 0 ]; do
  case "$1" in
    --in)  IN=${2:?}; shift 2;;
    --out) OUT=${2:?}; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

[ -n "${IN}" ]  || { echo "Missing --in";  exit 2; }
[ -n "${OUT}" ] || { echo "Missing --out"; exit 2; }
[ -f "${IN}" ]  || { echo "No such file: ${IN}"; exit 2; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT


"$TINYOS_CONF_SH" --tinyos-conf "$IN" --query |
awk '
# Top-level helper: double all dollars so Make sees them literally
function make_dollar_escape(s) { gsub(/\$/,"$$",s); return s }

{
  # Guaranteed KEY=VALUE by sed; split at first "="
  i = index($0, "="); k = substr($0, 1, i-1); v = substr($0, i+1)
  if (v == "") next  # preserve defaults

  # Escape dollar signs
  pv = make_dollar_escape(v)

  # “Tricky” if contains any of: # or \ (backslash).
  tricky = (v ~ /[#\\]/) ? 1 : 0
  if (tricky) {
    # Use a define-block to preserve literal # and trailing backslashes
    printf "define %s\n%s\nendef\n", k, pv
    printf "%s := $(value %s)\n", k, k
  } else {
    printf "%s := %s\n", k, pv
  }
}' > "$tmp"
# ensure trailing newline and write out
printf '\n' >> "$tmp"
mv -f "$tmp" "${OUT}"
