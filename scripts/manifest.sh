#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# manifest.sh — generate & verify TinyOS payload manifests
# =============================================================================
# Key features
# - Token management (read/new) backed by config via tinyos-conf.sh
# - Manifest generation: header + hash/size/file table (excluding manifests)
# - Manifest verification: re-generate table and diff (no tinyos.conf needed)
# - Stale manifest cleanup (keep only the current token's)
# - Build stamp helpers (generate/verify)
# - VFAT guardrails for filenames in the payload
# =============================================================================

# -----------------------------
# Policy: default hash program
# -----------------------------
HASH_ALG="${HASH_ALG:-sha256sum}"

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TINYOS_CONF_SH="$SCRIPT_DIR/tinyos-conf.sh"

MANIFEST_TEMPLATE="tinyos-{}.manifest"
subst_template() { printf '%s' "${1%\{\}*}$2${1#*\{\}}"; }

log()  { [ "${VERBOSE:-0}" -gt 0 ] && echo "[manifest] $*" >&2 || true; }
die()  { echo "[manifest] ERROR: $*" >&2; exit 1; }

# -----------------------------
# CLI parsing
# -----------------------------
usage() {
  cat >&2 <<'EOF'
Usage: manifest.sh [OPTIONS]
  --tinyos-conf  PATH  Path to config file (default: config/tinyos.conf)
  --payload      PATH  Path to staged payload (default: staging/payload)
  --new-token          Generate a new unique token (writes to tinyos.conf)
  --get-token          Print the existing token (fails if missing)
  --manifest-name      Print the manifest filename for current token
  --print-conf-hash    Print the hash of tinyos.conf (uses HASH_ALG)
  --generate-stamp PATH   Write TOKEN/HASH_ALG/CONF_HASH(+optional MANIFEST_*)
  --verify-stamp PATH     Verify stamp matches current config + manifest
  --remove-stale       Remove stale tinyos-*.manifest from payload (keep current)
  --generate           Generate a new manifest into PAYLOAD (uses tinyos.conf)
  --verify             Verify PAYLOAD against existing manifest (no config)
  --manifest PATH      Explicit manifest file to use (for --verify)
  --reset|--clean      Delete token from config and remove all manifests
  -v|--verbose         Verbose output
  -h|--help            Show this help and exit
EOF
}

needval() {
  local opt="$1" next="${2-}"
  [ -n "$next" ] && [ "${next#-}" != "$next" ] && die "missing value for $opt (got '$next')"
  [ -n "$next" ] || die "missing value for $opt"
}

TINYOS_CONF="${PROJECT_ROOT}/config/tinyos.conf"
PAYLOAD_DIR="${PROJECT_ROOT}/staging/payload"

NEW_TOKEN=0
GET_TOKEN=0
DEL_MANIFEST=0
GEN_MANIFEST=0
VERIFY=0
CLEAN=0

STAMP_OUT=""
STAMP_VERIFY=""
PRINT_NAME=0
PRINT_CONF_HASH=0
MANIFEST_IN=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)         usage; exit 2 ;;
    -v|--verbose)      VERBOSE=1; shift ;;
    --tinyos-conf)     needval "$1" "${2-}"; TINYOS_CONF="$2"; shift 2 ;;
    --payload)         needval "$1" "${2-}"; PAYLOAD_DIR="$2"; shift 2 ;;
    --new-token)       NEW_TOKEN=1; shift ;;
    --get-token)       GET_TOKEN=1; shift ;;
    --manifest-name)   PRINT_NAME=1; shift ;;
    --print-conf-hash) PRINT_CONF_HASH=1; shift ;;
    --generate-stamp)  needval "$1" "${2-}"; STAMP_OUT="$2"; shift 2 ;;
    --verify-stamp)    needval "$1" "${2-}"; STAMP_VERIFY="$2"; shift 2 ;;
    --remove-stale)    DEL_MANIFEST=1; shift ;;
    --generate)        GEN_MANIFEST=1; shift ;;
    --verify)          VERIFY=1; shift ;;
    --manifest)        needval "$1" "${2-}"; MANIFEST_IN="$2"; shift 2 ;;
    --reset|--clean)   CLEAN=1; shift ;;
    --)                shift; break ;;
    *)                 die "unknown arg: $1" ;;
  esac
done

# -----------------------------
# Token helpers
# -----------------------------
require_conf() { [ -f "$TINYOS_CONF" ] || die "missing config: $TINYOS_CONF"; }

read_token() {
  require_conf
  TINYOS_TOKEN="$("$TINYOS_CONF_SH" --tinyos-conf "$TINYOS_CONF" --query TINYOS_TOKEN || true)"
}

TOKEN_ALPHABET='abcdefghjkmnopqrstuvwxyz23456789'
[ ${#TOKEN_ALPHABET} -eq 32 ] || die "token alphabet must contain 32 chars"

generate_token() {
  mkdir -p "$(dirname -- "$TINYOS_CONF")"
  TINYOS_TOKEN="$(
    openssl rand 5 \
    | base32 \
    | tr 'A-Z2-7=' "${TOKEN_ALPHABET}=" \
    | sed -e 's/=*$//' -e 's/r[rn]/xm/g' -e 's/vv/yu/g'
  )"
  "$TINYOS_CONF_SH" --tinyos-conf "$TINYOS_CONF" --update TINYOS_TOKEN="$TINYOS_TOKEN"
}

manifest_name() {
  [ -n "${TINYOS_TOKEN:-}" ] || read_token
  [ -n "${TINYOS_TOKEN:-}" ] || die "no token available"
  subst_template "$MANIFEST_TEMPLATE" "$TINYOS_TOKEN"
}

# -----------------------------
# Hash helpers
# -----------------------------
hash_norm() {
  awk '{
    match($0,/^([^[:space:]]+)[[:space:]]+([^[:space:]].*)$/,m)
    printf "%s\t%s\n", m[1], m[2]
  }'
}

hash_file() { # echo only the hash (first field)
  if [ -f "$1" ] && [ -s "$1" ]; then
    "$HASH_ALG" -- "$1" | hash_norm | awk '{ printf "%s", $1 }'
  else
    printf ''
  fi
}

# -----------------------------
# Stamp helpers
# -----------------------------
write_stamp() {
  local out="$1" tok confh man= manh=

  require_conf
  read_token
  if [ -z "${TINYOS_TOKEN:-}" ]; then
    generate_token
  fi

  tok="$TINYOS_TOKEN"
  confh="$(hash_file "$TINYOS_CONF")"
  if [ -f "${PAYLOAD_DIR}/$(manifest_name)" ]; then
    man="$(manifest_name)"
    manh="$(hash_file "${PAYLOAD_DIR}/${man}")"
  fi

  mkdir -p "$(dirname -- "$out")"
  {
    echo "TOKEN=$tok"
    echo "HASH_ALG=$HASH_ALG"
    echo "CONF_HASH=$confh"
    echo "MANIFEST_NAME=$man"
    echo "MANIFEST_HASH=$manh"
  } > "$out"
}

verify_stamp() {
  local path="$1" tokf algf hashf manf tokc algc hashc manc

  [ -s "$path" ] || {
    echo "[manifest] ERROR: stamp missing: $path" >&2
    return 1
  }

  tokf="$(awk -F= '/^TOKEN=/{print $2}' "$path" 2>/dev/null)"
  algf="$(awk -F= '/^HASH_ALG=/{print $2}' "$path" 2>/dev/null)"
  hashf="$(awk -F= '/^CONF_HASH=/{print $2}' "$path" 2>/dev/null)"
  manf="$(awk -F= '/^MANIFEST_HASH=/{print $2}' "$path" 2>/dev/null)"

  require_conf
  read_token
  tokc="$TINYOS_TOKEN"
  algc="$HASH_ALG"
  hashc="$(hash_file "$TINYOS_CONF")"
  manc="$(hash_file "${PAYLOAD_DIR}/$(manifest_name)")"

  [ -z "$tokf" ] || [ "$tokf" = "$tokc" ] || \
    die "token drift (file=$tokf, current=$tokc)"
  [ -z "$algf" ] || [ "$algf" = "$algc" ] || \
    die "conf hash alg drift (file=$algf, current=$algc)"
  [ -z "$hashf" ] || [ "$hashf" = "$hashc" ] || \
    die "tinyos.conf drift"
  [ -z "$manf" ] || [ "$manf" = "$manc" ] || \
    die "manifest drift"
}

# Early fast-paths
if [ -n "$STAMP_OUT" ]; then
  write_stamp "$STAMP_OUT"; exit 0
elif [ -n "$STAMP_VERIFY" ]; then
  verify_stamp "$STAMP_VERIFY"; exit $?
elif [ "$PRINT_NAME" -eq 1 ]; then
  read_token; manifest_name; exit 0
elif [ "$PRINT_CONF_HASH" -eq 1 ]; then
  hash_file "$TINYOS_CONF"; exit 0
fi

# -----------------------------
# VFAT safety filter (reject on bad names)
# -----------------------------
vfat_filter0() {
  # read NUL-delimited from stdin; write NUL-delimited to stdout
  awk -v RS=$'\0' '
    function bad(why, s) {
      gsub(/[[:cntrl:]]/, "?", s);
      printf("VFAT-unsafe: %s (%s)\n", why, s) > "/dev/stderr";
      exit 1;
    }
    {
      s = $0;
      if (s ~ /[<>:\"\\/|?*]/)  bad("reserved character", s)
      if (s ~ /[[:cntrl:]]/)    bad("control character",  s)
      n = split(s, c, /\//)
      for (i = 1; i <= n; i++) {
        if (c[i] ~ /[ \.]$/)    bad("component ends with space/dot", s)
        if (length(c[i]) > 255) bad("component too long", s)
      }
      printf "%s\0", s
    }'
}

# -----------------------------
# GENERATE or VERIFY mode (writes into PAYLOAD)
# -----------------------------
if [ "$GEN_MANIFEST" -eq 1 ] || [ "$VERIFY" -eq 1 ]; then
  [ -d "$PAYLOAD_DIR" ] || die "missing payload: $PAYLOAD_DIR"

  if [ "$VERIFY" -eq 1 ]; then
    # Locate manifest
    if [ -n "$MANIFEST_IN" ]; then
      [ -f "$MANIFEST_IN" ] || die "manifest not found: $MANIFEST_IN"
    else
      mapfile -t -d "" _cands < <(
        find "$PAYLOAD_DIR" \
          -mindepth 1 -maxdepth 1 -type f \
          -iname "$(subst_template "$MANIFEST_TEMPLATE" '*')" \
          -print0)
      case "${#_cands[@]}" in
        1) MANIFEST_IN="${_cands[0]}" ;;
        *) die "payload must contain exactly one tinyos-*.manifest (found ${#_cands[@]})" ;;
      esac
    fi

    # Read manifest version
    mver="$(awk -F= '/^MANIFEST_VERSION=/{print $2}' "$MANIFEST_IN" | head -n1)"
    [ "$mver" == '1.0.0' ] || \
      die "Unexpected manifest version: $mver"

    # Read algorithm and token; enforce name↔token
    HASH_ALG="$(awk -F= '/^FILE_HASH=/{print $2}' "$MANIFEST_IN" | head -n1)"
    tok="$(awk -F= '/^TINYOS_TOKEN=/{print $2}' "$MANIFEST_IN" | head -n1)"
    [ -n "$HASH_ALG" ] || die "manifest missing FILE_HASH"
    [ -n "$tok" ] || die "manifest missing TINYOS_TOKEN"

    base="$(basename -- "$MANIFEST_IN")"
    expect="$(subst_template "$MANIFEST_TEMPLATE" "$tok")"
    [ "$base" = "$expect" ] || \
      die "manifest filename '$base' does not match token '$tok' (expected '$expect')"

  fi

  command -v "$HASH_ALG" > /dev/null 2>&1 || \
    die "hash program not found: $HASH_ALG"
  HASH_WIDTH=$("$HASH_ALG" /dev/null | hash_norm | awk '{ print length($1) }')

  MANIFEST_TMP="$(mktemp "${PAYLOAD_DIR}/.manifest.XXXXXX.tmp")"
  SORTED_TMP="$(mktemp "${PAYLOAD_DIR}/.manifest.XXXXXX.sorted")"
  trap 'rm -f "$MANIFEST_TMP" "$SORTED_TMP" 2>/dev/null || true' EXIT

  if [ "$GEN_MANIFEST" -eq 1 ]; then
    require_conf
    read_token
    if [ -z "${TINYOS_TOKEN:-}" ]; then
      generate_token
    fi
    MANIFEST_OUT="$(manifest_name)"

    BUILD_DATE_TS="$(date -u '+%s')"
    BUILD_DATE_ISO="$(date -u -d "@${BUILD_DATE_TS}" '+%Y-%m-%dT%H:%M:%SZ')"
    BUILD_DATE_HUMAN="$(date -d "@${BUILD_DATE_TS}" '+%a %b %d %H:%M:%S %Z %Y')"
    GIT_HASH="$(cd "$PROJECT_ROOT"; git rev-parse HEAD 2>/dev/null || true)"
  fi
  {
    if [ "$GEN_MANIFEST" -eq 1 ]; then
      echo "# tinyos manifest, generated $BUILD_DATE_HUMAN"
      echo "# DO NOT delete this file! It is needed to locate the tinyos payload at boot"
      echo "MANIFEST_VERSION=1.0.0"
      echo "BUILD_DATE=$BUILD_DATE_ISO"
      echo "GIT_HASH=$GIT_HASH"
      echo "FILE_HASH=$HASH_ALG"
      "$TINYOS_CONF_SH" \
        --tinyos-conf "$TINYOS_CONF" \
        --query \
      | sed \
          -e '/^MANIFEST_VERSION=/d' \
          -e '/^BUILD_DATE=/d' \
          -e '/^GIT_HASH=/d' \
          -e '/^FILE_HASH=/d'
      echo ""
      echo "--"
      awk -v w="$HASH_WIDTH" 'BEGIN {
        printf "%-"w"s %10s %s\n", "# HASH", "SIZE", "FILENAME"
      }'
    fi

    cd "$PAYLOAD_DIR"

    # Exclude ALL manifest files from the table (they are metadata, not payload)
    find . -type f -printf '%P\0' \
    | grep -zvF \
        -e "$(subst_template "$MANIFEST_TEMPLATE" '*')" \
        -e "$(basename -- "$MANIFEST_TMP")" \
        -e "$(basename -- "$SORTED_TMP")" \
    | vfat_filter0 \
    | LC_ALL=C sort -z > "$SORTED_TMP"

    # Join calculated hashes and sizes on filename
    LC_ALL=C join -j 2 -t $'\t' -o 1.1,2.1,0 -e - \
      <(xargs -0a "$SORTED_TMP" -r "$HASH_ALG" -- | hash_norm ) \
      <(xargs -0a "$SORTED_TMP" -r stat -c $'%s	%n' -- ) \
    | awk -v w="$HASH_WIDTH" '{
        printf "%-"w"s %10s %s\n", $1, $2, $3
      }'

    rm -f -- "$SORTED_TMP" 2>/dev/null || true
  } > "$MANIFEST_TMP"

  if [ "$GEN_MANIFEST" -eq 1 ]; then
    mv -f -- "$MANIFEST_TMP" "$PAYLOAD_DIR/$MANIFEST_OUT"
    log "generated $PAYLOAD_DIR/$MANIFEST_OUT"
  elif [ "$VERIFY" -eq 1 ]; then
    diff="$(
      { diff -U1 \
        <(awk '
            BEGIN{inhdr=1}
            /^--/{inhdr=0;next}
            inhdr==1{next}
            NF>=3{
              if($1 ~ /^#/) next;
              print
            }
          ' "$MANIFEST_IN" \
          | LC_ALL=C sort -u
        ) \
        <(LC_ALL=C sort -u < "$MANIFEST_TMP") \
      | tail -n+3 | grep '^[+-]'; } || true
    )"
    rm -f "$MANIFEST_TMP"

    if [ -z "$diff" ]; then
      log "verify: OK"
      exit 0
    else
      echo "[manifest] verify: mismatch between manifest and payload" >&2
      echo "$diff" >&2
      exit 1
    fi
  fi
fi

# -----------------------------
# Remove stale manifests / clean token
# -----------------------------
if [ "$DEL_MANIFEST" -eq 1 ] || [ "$CLEAN" -eq 1 ]; then
  # Keep only current token's manifest when token is known
  keep=""
  if [ "$DEL_MANIFEST" -eq 1 ]; then
    read_token || true
    if [ -n "${TINYOS_TOKEN:-}" ]; then
      keep="$(manifest_name)"
    fi
  fi
  find "$PAYLOAD_DIR" -mindepth 1 -maxdepth 1 -type f \
    -iname "$(subst_template "$MANIFEST_TEMPLATE" '*')" -printf '%P\0' \
  | { if [ -n "$keep" ]; then grep -zvF -- "$keep"; else cat; fi; } \
  | xargs -r0 rm -f --
fi

if [ "$CLEAN" -eq 1 ]; then
  "$TINYOS_CONF_SH" \
    --tinyos-conf "$TINYOS_CONF" \
    --delete TINYOS_TOKEN \
  || true
  log "token removed from $TINYOS_CONF"
fi
