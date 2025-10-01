#!/usr/bin/env bash
# tinyos-conf.sh — query, normalize & merge tinyos.conf
#
# Grammar (simplified):
#   • Each non-blank line is EITHER a full-line comment or an assignment.
#   • Comments:      ^\s*#.*$
#   • Assignments:   ^\s*KEY\s*=\s*VALUE\s*$
#   • There are NO inline comments. A '#' is just data unless it’s at
#     the start of a line (after optional whitespace).
#   • Whitespace around '=' is permitted; comparison normalizes it.
#
# Usage:
#   tinyos-conf.sh \
#     --tinyos-conf PATH \
#     --query [KEY]...
#
#     Query configuration values.
#       - With no KEYs, outputs all KEY=VALUE pairs.
#       - With one KEY, outputs just VALUE (error if missing).
#       - With multiple KEYs, outputs KEY=VALUE lines.
#
#   tinyos-conf.sh \
#     --tinyos-conf PATH \
#     --update [KEY=VALUE]... \
#     [--unset KEY]... \
#     [--delete KEY]...
#
#     Update configuration values.
#       - KEY=VALUE sets or updates KEY.
#       - --unset KEY writes KEY with an empty value (KEY=).
#       - --delete KEY removes KEY from the file entirely.
#
# Options:
#   -v|--verbose   Verbose logging to stderr
#   -h|--help      Show this help and exit
#
# Notes:
#   • Missing file is treated as empty (/dev/null is used)
#   • Updates rewrite the file normalized and idempotent

set -euo pipefail

log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[tinyos-conf] $*" >&2 || true; }
die(){ echo "[tinyos-conf] ERROR: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage:
  tinyos-conf.sh --tinyos-conf PATH --query [KEY]...
  tinyos-conf.sh --tinyos-conf PATH --update [KEY=VALUE]... [--unset KEY]... [--delete KEY]...

Options:
  -v|--verbose                 Verbose logging
  -h|--help                    Show this help

Notes:
  • Missing file is treated as empty (read /dev/null)
  • Writes are normalized and idempotent
EOF
  exit 2
}

# require a following value for an option; reject if missing or looks like another option
needval() {
  local opt="$1" next="${2-}"
  [ -n "$next" ] && [ "${next#-}" != "$next" ] && die "missing value for $opt (got '$next')"
  [ -n "$next" ] || die "missing value for $opt"
}
is_key(){ [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]]; }

declare -a SETS=() DELS=() QKEYS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)         usage;;
    -v|--verbose)      VERBOSE=1; shift;;
    --tinyos-conf)     needval "$1" "${2-}"; TINYOS_CONF="$2"; shift 2;;
    --query)           ACTION=query; shift; break;;
    --update)          ACTION=update; shift; break;;
    *) die "unknown arg: $1";;
  esac
done
[ -n "$ACTION" ] || die "action (--update or --delete) is required"

[ -n "$TINYOS_CONF" ] || die "--tinyos-conf PATH is required"

case "$ACTION" in
  query)
    # parse remaining tokens as keys
    while [ $# -gt 0 ]; do
      case "$1" in
        -v|--verbose) VERBOSE=1; shift;;
        -h|--help)    usage;;
        [A-Z]*)       is_key "$1" || die "invalid key: $1"
                      QKEYS+=("$1")
                      shift;;
        *) die "unexpected query arg: $1";;
      esac
    done
    ;;
  update)
    # parse KEY=VALUE / --unset KEY / --delete KEY
    while [ $# -gt 0 ]; do
      case "$1" in
        -v|--verbose) VERBOSE=1; shift;;
        -h|--help)    usage;;
        --unset)      needval "$1" "${2-}"
                      is_key "$2" || die "invalid key: $2"
                      SETS+=("$2=")
                      shift 2;;
        --delete)     needval "$1" "${2-}"
                      is_key "$2" || die "invalid key: $2"
                      DELS+=("$2")
                      shift 2;;
        [A-Z]*=*)     key="${1%%=*}"
                      is_key "$key" || die "invalid key: $key"
                      SETS+=("$1")
                      shift;;
        *) die "unexpected update arg: $1";;
      esac
    done
    ;;
  *) usage;;
esac

# Pick input: existing file or /dev/null (same code path either way)
infile="/dev/null"
[ -f "$TINYOS_CONF" ] && infile="$TINYOS_CONF"

# Canonicalize for change detection (ignore full-line comments/blank lines).
# Keep only KEY=VALUE assignments and normalize spaces around '='.
normalize_assignments() {
  # Notes:
  #  • drop CR
  #  • trim leading/trailing space
  #  • normalize spaces around "="
  #  • keep only KEY=VALUE lines
  sed -rn \
    -e 's/\r$//' \
    -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
    -e 's/[[:space:]]*=[[:space:]]*/=/' \
    -e '/^[A-Z_][A-Z0-9_]*=.*/p' \
    "$1"
}

# Query keys, output KEY=VALUE lines for each matching key.
# For a single key only: output just the value, fail on missing key.
action_query() {
  if   [ ${#QKEYS[@]} -eq 0 ]; then
    normalize_assignments "$infile"
  elif [ ${#QKEYS[@]} -eq 1 ]; then
    normalize_assignments "$infile" | awk \
      -v qstr="${QKEYS[0]}" '
      {
        if (! match($0, /^([A-Z_][A-Z0-9_]*)=(.*)$/, kv)) next;
        if (kv[1] == qstr) {
          printf "%s\n", kv[2];
          exit 0;
        }
      }
      END{
        # Single key not found
        exit 1
      }
    '
  else
    normalize_assignments "$infile" | awk \
      -v qstr="$(printf '%s\n' "${QKEYS[@]}")" '
      BEGIN{
        n = split(qstr, qraw, "\n"); for (i=1; i<=n; i++) {
          if (match(qraw[i], /^([A-Z][A-Z0-9_]*)$/, k)) keys[k[1]]=1;
        }
      }
      {
        if (! match($0, /^([A-Z][A-Z0-9_]*)=(.*)$/, kv)) next;
        k=kv[1]; v=kv[2];
        if (k in keys) {
          printf "%s=%s\n", k, v;
          next;
        }
      }
    '
  fi
}

# Overwrite managed keys in place, preserving:
#  • line order
#  • leading whitespace
#  • original spacing around '='
# If a managed key is missing, append it at end.
action_update() {
  log "Updating config → $TINYOS_CONF"

  mkdir -p "$(dirname "$TINYOS_CONF")"
  tmp="${TINYOS_CONF}.tmp.$$"; trap 'rm -f "$tmp" 2>/dev/null || true' EXIT

  # AWK does the in-place managed-key rewrite while preserving formatting of
  # unmanaged lines and spacing around '=' on managed lines.
  # Trimming of provided values happens *inside* AWK.
  awk \
    -v sstr="$(printf '%s\n' "${SETS[@]}")" \
    -v dstr="$(printf '%s\n' "${DELS[@]}")" '

    # Trim leading and trailing spaces
    function trim(s,   t) {
      t = s
      sub(/^[[:space:]]+/, "", t)
      sub(/[[:space:]]+$/, "", t)
      return t
    }
    BEGIN {
      n = split(sstr, sraw, "\n"); for (i=1; i<=n; i++) {
        if (match(sraw[i], /^([A-Z][A-Z0-9_]*)=(.*)$/, kv)) sets[kv[1]]=kv[2];
      }
      n = split(dstr, draw, "\n"); for (i=1; i<=n; i++) {
        if (match(draw[i], /^([A-Z][A-Z0-9_]*)$/, k)) dels[k[1]]=1;
      }
    }
    # Parse: ^(lead)(KEY)(ws1)=(ws2)(VALUE)(ws3)$  (no inline comments)
    # We keep lead, ws1, ws2 exactly as-is.
    {
      line=$0
      if (match(line, /^([[:space:]]*)([A-Z][A-Z0-9_]*)([[:space:]]*)=([[:space:]]*)/, m)) {
        key = m[2]
        if (key in dels) next;
        if (key in sets) {
          val = trim(sets[key])
          # Preserve formatting: m[1] key m[3] "=" m[4] value
          out = m[1] key m[3] "=" m[4] val
          print out
          seen[key]=1
          next
        }
      }
      # Unmanaged or non-assignments: pass through
      print line
    }
    END{
      # Append any missing managed keys
      for (k in sets) {
        if (!seen[k]) {
          v = trim(sets[k])
          print k "=" v
        }
      }
    }
  ' "$infile" >"$tmp"

  # Only replace the file if the normalized content differs
  if [ -f "$TINYOS_CONF" ]; then
    if cmp -s \
        <(normalize_assignments "$tmp" | sort -u) \
        <(normalize_assignments "$TINYOS_CONF" | sort -u); then
      rm -f "$tmp"
      log "No change to $TINYOS_CONF"
      exit 0
    fi
  fi
  mv -f "$tmp" "$TINYOS_CONF"
}

case "$ACTION" in
  query)   action_query;;
  update)  action_update;;
  *)       die "unimplemented action: $ACTION"
esac
