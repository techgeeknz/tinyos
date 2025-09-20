#!/usr/bin/env bash
# tinyos-conf.sh — normalize & merge tinyos.conf
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
#     --tinyos-conf   PATH            # default: ./config/tinyos.conf
#     [--tools-mount  PATH]           # e.g. /boot/hp_tools (absolute, normalized)
#     [--tinyos-rel   RELPATH]        # e.g. EFI/tinyos (no leading slash)
#     [--bootdir      PATH]           # if set, reconciles tools-mount/tinyos-rel from this
#     [--install-name FILENAME]
#     [--esp-mount    PATH]           # optional; auto-detected if not supplied
#   Env:
#     VERBOSE=0|1   - logs when >0

set -euo pipefail

log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[tinyos-conf] $*" >&2 || true; }
die(){ echo "[tinyos-conf] ERROR: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: tinyos-conf.sh [OPTIONS]
  --tinyos-conf   PATH         Path to config file (default: ./config/tinyos.conf)
  --tools-mount   PATH         Absolute mount for HP_TOOLS (e.g. /boot/hp_tools)
  --tinyos-rel    RELPATH      Relative path under tools mount (e.g. EFI/tinyos)
  --bootdir       PATH         If set, reconciles tools-mount/tinyos-rel from PATH
  --install-name  FILENAME     Output EFI app name (e.g. tinyos.efi)
  --esp-mount     PATH         Explicit ESP mount (absolute); otherwise auto-detect
  -v|--verbose                 Verbose logging
  -h|--help                    Show this help
Notes:
  * Only --opt VALUE form is accepted (no --opt=value).
  * File is only rewritten if managed keys actually change.
EOF
  exit 2
}

# require a following value for an option; reject if missing or looks like another option
needval() {
  local opt="$1" next="${2-}"
  [ -n "$next" ] && [ "${next#-}" != "$next" ] && die "missing value for $opt (got '$next')"
  [ -n "$next" ] || die "missing value for $opt"
}

TINYOS_CONF="${PWD}/config/tinyos.conf"
TOOLS_MOUNT_IN=""
TINYOS_REL=""
BOOTDIR=""
INSTALL_NAME=""
ESP_MOUNT_IN=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)         usage;;
    -v|--verbose)      VERBOSE=1; shift;;
    --tinyos-conf)     needval "$1" "${2-}"; TINYOS_CONF="$2"; shift 2;;
    --tools-mount)     needval "$1" "${2-}"; TOOLS_MOUNT_IN="$2"; shift 2;;
    --tinyos-rel)      needval "$1" "${2-}"; TINYOS_REL="$2"; shift 2;;
    --bootdir)         needval "$1" "${2-}"; BOOTDIR="$2"; shift 2;;
    --install-name)    needval "$1" "${2-}"; INSTALL_NAME="$2"; shift 2;;
    --esp-mount)       needval "$1" "${2-}"; ESP_MOUNT_IN="$2"; shift 2;;
    --) shift; break;;
    *) die "unknown arg: $1";;
  esac
done

# Defaults if not provided (match Makefile defaults)
TOOLS_MOUNT="${TOOLS_MOUNT:-/boot/hp_tools}"
TINYOS_REL="${TINYOS_REL:-EFI/tinyos}"
ESP_MOUNT="${ESP_MOUNT:-/boot/esp}"

# Normalize
TOOLS_MOUNT="${TOOLS_MOUNT%/}"
TINYOS_REL="${TINYOS_REL#/}"
TINYOS_REL="${TINYOS_REL%/}"
BOOTDIR="${BOOTDIR%/}"
[ -n "$INSTALL_NAME" ] && INSTALL_NAME="$(basename -- "$INSTALL_NAME")" || true

case "$TOOLS_MOUNT" in
  /*) : ;;
  *) die "TOOLS_MOUNT must be absolute (got '$TOOLS_MOUNT')" ;;
esac
if [ -n "$ESP_MOUNT_IN" ]; then
  case "$ESP_MOUNT_IN" in
    /*) : ;;
    *) die "ESP_MOUNT must be absolute (got '$ESP_MOUNT_IN')" ;;
  esac
fi

# Reconcile from BOOTDIR if provided or implied inconsistent
if [ -n "$BOOTDIR" ] && [ "${TOOLS_MOUNT}/${TINYOS_REL}" != "$BOOTDIR" ]; then
  case "$BOOTDIR" in
    */EFI/*)
      TOOLS_MOUNT="${BOOTDIR%%/EFI/*}"
      TINYOS_REL="${BOOTDIR#${TOOLS_MOUNT}/}"
      ;;
    *)
      TOOLS_MOUNT="$BOOTDIR"
      TINYOS_REL="EFI/tinyos"
      ;;
  esac
fi

# Re-normalize and validate
TINYOS_REL="${TINYOS_REL#/}"
TINYOS_REL="${TINYOS_REL%/}"
case "$TINYOS_REL" in *..*) die "TINYOS_REL must not contain '..'";; esac



mkdir -p "$(dirname "$TINYOS_CONF")"
tmp="${TINYOS_CONF}.tmp.$$"

log "Writing normalized config → $TINYOS_CONF"
# Overwrite managed keys in place, preserving:
#  • line order
#  • leading whitespace
#  • original spacing around '='
# If a managed key is missing, append it at end.
# Values may be quoted to preserve leading/trailing spaces.

# Pick input: existing file or /dev/null (same code path either way)
infile="/dev/null"
[ -f "$TINYOS_CONF" ] && infile="$TINYOS_CONF"

# AWK does the in-place managed-key rewrite while preserving formatting of
# unmanaged lines and spacing around '=' on managed lines.
# Trimming of provided values happens *inside* AWK.
awk \
  -v v_TOOLS_MOUNT="$TOOLS_MOUNT" \
  -v v_TINYOS_REL="$TINYOS_REL" \
  -v v_ESP_MOUNT="$ESP_MOUNT" \
  -v v_INSTALL_NAME="$INSTALL_NAME" '

  # Trim leading and trailing spaces
  function trim(s,   t) {
    t = s
    sub(/^[[:space:]]+/, "", t)
    sub(/[[:space:]]+$/, "", t)
    return t
  }
  BEGIN {
    if (length(v_TOOLS_MOUNT))  managed["TOOLS_MOUNT"]  = trim(v_TOOLS_MOUNT)
    if (length(v_TINYOS_REL))   managed["TINYOS_REL"]   = trim(v_TINYOS_REL)
    if (length(v_ESP_MOUNT))    managed["ESP_MOUNT"]    = trim(v_ESP_MOUNT)
    if (length(v_INSTALL_NAME)) managed["INSTALL_NAME"] = trim(v_INSTALL_NAME)
  }
  # Parse: ^(lead)(KEY)(ws1)=(ws2)(VALUE)(ws3)$  (no inline comments)
  # We keep lead, ws1, ws2 exactly as-is.
  {
    line=$0
    if (match(line, /^([[:space:]]*)([A-Z_][A-Z0-9_]*)([[:space:]]*)=([[:space:]]*).*$/, m)) {
      key = m[2]
      if (key in managed) {
        val = managed[key]
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
    for (k in managed) {
      if (!seen[k]) {
        v = managed[k]
        print k "=" v
      }
    }
  }
  ' "$infile" >"$tmp"


# Canonicalize for change detection (ignore full-line comments/blank lines).
# Keep only KEY=VALUE assignments and normalize spaces around '='.
normalize_assignments() {
  # Notes:
  #  • drop CR
  #  • strip whole line comments
  #  • trim leading/trailing space
  #  • normalize spaces around "="
  #  • keep only KEY=VALUE lines
  sed -rn \
    -e 's/\r$//' \
    -e '/^[[:space:]]*#/d' \
    -e '/^[[:space:]]*$/d' \
    -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
    -e 's/[[:space:]]*=[[:space:]]*/=/' \
    -e '/^[A-Z_][A-Z0-9_]*=.*/p' \
    "$1"
}

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
