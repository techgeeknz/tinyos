#!/usr/bin/env bash
# update-tinyos-conf.sh — normalize & merge tinyos.conf
# Grammar (simplified):
#   (ESP/TOOLS auto-detection is best-effort and only emits keys when confident)
#   • Each non-blank line is EITHER a full-line comment or an assignment.
#   • Comments:      ^\s*#.*$
#   • Assignments:   ^\s*KEY\s*=\s*VALUE\s*$
#   • There are NO inline comments. A '#' is just data unless it’s at
#     the start of a line (after optional whitespace).
#   • Whitespace around '=' is permitted; comparison normalizes it.
#
# Usage:
#   update-tinyos-conf.sh \
#     --tinyos-conf   PATH            # default: ./config/tinyos.conf
#     [--tools-mount  PATH]           # e.g. /boot/hp_tools (absolute, normalized)
#     [--tinyos-rel   RELPATH]        # e.g. EFI/tinyos (no leading slash)
#     [--bootdir      PATH]           # if set, reconciles tools-mount/tinyos-rel from this
#     [--install-name FILENAME]
#     [--esp-mount    PATH]           # optional; auto-detected if not supplied
#     [--no-esp-detect]               # optional; disable ESP autodetection
#   Env:
#     VERBOSE=0|1   - logs when >0

set -euo pipefail

log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[update-tinyos-conf] $*" >&2 || true; }
die() { echo "[update-tinyos-conf] ERROR: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: update-tinyos-conf.sh [OPTIONS]
  --tinyos-conf   PATH         Path to config file (default: ./config/tinyos.conf)
  --tools-mount   PATH         Absolute mount for HP_TOOLS (e.g. /boot/hp_tools)
  --tinyos-rel    RELPATH      Relative path under tools mount (e.g. EFI/tinyos)
  --bootdir       PATH         If set, reconciles tools-mount/tinyos-rel from PATH
  --install-name  FILENAME     Output EFI app name (e.g. tinyos.efi)
  --esp-mount     PATH         Explicit ESP mount (absolute); otherwise auto-detect
  --no-esp-detect              Disable ESP autodetection
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
TOOLS_DETECT=1
ESP_DETECT=1

# Derived/hints (only set when confidently detected)
ESP_HINT=""
TOOLS_HINT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)         usage;;
    -v|--verbose)      VERBOSE=1; shift;;
    --no-tools-detect) TOOLS_DETECT=0; shift;;
    --no-esp-detect)   ESP_DETECT=0; shift;;
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

# ESP detection (optional; can be disabled)
ESP_MOUNT="${ESP_MOUNT_IN%/}"
if [ -z "$ESP_MOUNT" ] && [ "$ESP_DETECT" -eq 1 ] && [ -d /sys/firmware/efi ]; then
  if mountpoint -q /boot/efi; then
    ESP_MOUNT="/boot/efi"
  else
    ESP_MOUNT="$(findmnt -nr -t vfat -o TARGET 2>/dev/null | head -n1 || true)"
  fi
fi
ESP_MOUNT="${ESP_MOUNT%/}"

# ---------------------------
# Best-effort ESP/HP_TOOLS detection
# ---------------------------
# Tools we may use (all optional; skip gracefully if missing)
have_findmnt=0; command -v findmnt >/dev/null 2>&1 && have_findmnt=1
have_lsblk=0;   command -v lsblk  >/dev/null 2>&1 && have_lsblk=1

# Small helpers
mnt_src() {
  [ "$have_findmnt" -eq 1 ] && findmnt -nr -o SOURCE --target "$1" 2>/dev/null || true
}

mnt_fstype() {
  [ "$have_findmnt" -eq 1 ] && findmnt -nr -o FSTYPE --target "$1" 2>/dev/null || true
}

fstab_target_for_type(){
  # Find first VFAT-ish fstab entry that looks like an ESP (/boot/efi common)
  [ "$have_findmnt" -eq 1 ] || return 0
  findmnt -snr -t vfat,fat,fat32 -o TARGET 2>/dev/null | head -n1 || true
}

identify_part_hints(){
  # Args: $1 = block device path (e.g. /dev/nvme0n1p1)
  # Echo two fields: PARTUUID  UUID   (if available; blank if not)
  local dev="$1"
  [ "$have_lsblk" -eq 1 ] || { echo " "; return; }
  lsblk -nr -o PARTUUID,UUID "$dev" 2>/dev/null | head -n1 || echo " "
}

scan_for_esp(){
  # Return mountpoint and hint for ESP when not already mounted/known
  # Strategy:
  #   1) Prefer live mount /boot/efi (VFAT)
  #   2) Else first mounted VFAT that looks like ESP
  #   3) Else scan GPT for PARTTYPE=EFI (c12a7328-f81f-11d2-ba4b-00a0c93ec93b)
  local mp src ty dev ptu uid
  # 1) /boot/efi live mount
  if [ -d /sys/firmware/efi ] && [ -d /boot/efi ] && mountpoint -q /boot/efi; then
    ty="$(mnt_fstype /boot/efi)"
    if [ "$ty" = "vfat" ] || [ "$ty" = "fat" ] || [ "$ty" = "fat32" ]; then
      mp="/boot/efi"; src="$(mnt_src "$mp")"
      read ptu uid < <(identify_part_hints "$src")
      echo "$mp" "$src" "$ptu" "$uid"
      return
    fi
  fi
  # 2) some mounted VFAT (first)
  if [ "$have_findmnt" -eq 1 ]; then
    mp="$(findmnt -nr -t vfat,fat,fat32 -o TARGET 2>/dev/null | head -n1 || true)"
    if [ -n "$mp" ]; then
      src="$(mnt_src "$mp")"
      read ptu uid < <(identify_part_hints "$src")
      echo "$mp" "$src" "$ptu" "$uid"
      return
    fi
  fi
  # 3) scan GPT PARTTYPE for EFI System Partition GUID
  if [ "$have_lsblk" -eq 1 ]; then
    # Search for partition type GUID (lower/upper accepted)
    dev="$(lsblk -nr -o NAME,TYPE,PARTTYPE | awk 'toupper($3)=="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"{print $1; exit}')"
    if [ -n "$dev" ]; then
      dev="/dev/${dev}"
      # No mountpoint yet; let init mount it. Provide hints only.
      read ptu uid < <(identify_part_hints "$dev")
      echo "" "$dev" "$ptu" "$uid"
      return
    fi
  fi
  echo "" "" "" ""
}

scan_for_hp_tools(){
  # Return mountpoint and hint for HP_TOOLS if present
  # Strategy:
  #   1) If /boot/hp_tools is a mountpoint, use it
  #   2) Else find label HP_TOOLS via lsblk
  local mp src dev ptu uid
  if [ -d /boot/hp_tools ] && mountpoint -q /boot/hp_tools; then
    mp="/boot/hp_tools"; src="$(mnt_src "$mp")"
    read ptu uid < <(identify_part_hints "$src")
    echo "$mp" "$src" "$ptu" "$uid"
    return
  fi
  if [ "$have_lsblk" -eq 1 ]; then
    dev="$(lsblk -nr -o NAME,LABEL,TYPE | awk '$3=="part" && $2=="HP_TOOLS"{print $1; exit}')"
    if [ -n "$dev" ]; then
      dev="/dev/${dev}"
      read ptu uid < <(identify_part_hints "$dev")
      echo "" "$dev" "$ptu" "$uid"
      return
    fi
  fi
  echo "" "" "" ""
}

# 1) ESP_MOUNT (respect CLI override)
ESP_MOUNT="${ESP_MOUNT_IN%/}"
if [ "$ESP_DETECT" -eq 1 ] && [ -z "$ESP_MOUNT" ]; then
  read _mp _src _ptu _uid < <(scan_for_esp)
  if [ -n "$_mp" ]; then
    ESP_MOUNT="$_mp"
  else
    # Fallback: consult fstab (static) for a vfat target
    _mp="$(fstab_target_for_type)"
    [ -n "$_mp" ] && ESP_MOUNT="$_mp" || true
  fi
  # Hints (only if we know the device)
  if [ -n "$_src" ]; then
    if [ -n "$_ptu" ]; then ESP_HINT="PARTUUID=${_ptu}"
    elif [ -n "$_uid" ]; then ESP_HINT="UUID=${_uid}"
    fi
  fi
fi
ESP_MOUNT="${ESP_MOUNT%/}"

# 2) HP_TOOLS hints (mount path & device)
read _hmp _hsrc _hptu _huid < <(scan_for_hp_tools)
# Prefer discovered mount only if user didn’t specify TOOLS_MOUNT
if [ "$TOOLS_DETECT" -eq 1 ] && [ -z "$BOOTDIR" ] && [ -z "$TOOLS_MOUNT_IN" ] && [ -n "$_hmp" ]; then
  TOOLS_MOUNT="$_hmp"
fi
if [ -n "$_hsrc" ]; then
  if   [ -n "$_hptu" ]; then TOOLS_HINT="PARTUUID=${_hptu}"
  elif [ -n "$_huid" ]; then TOOLS_HINT="UUID=${_huid}"
  fi
fi

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
  -v v_ESP_HINT="$ESP_HINT" \
  -v v_TOOLS_HINT="$TOOLS_HINT" \
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
    if (length(v_ESP_HINT))     managed["ESP_HINT"]     = trim(v_ESP_HINT)
    if (length(v_TOOLS_HINT))   managed["TOOLS_HINT"]   = trim(v_TOOLS_HINT)
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

# Always run the same AWK rewrite even when the conf file doesn’t exist.
# (Empty input is equivalent to an empty file.)
if [ ! -f "$TINYOS_CONF" ]; then
  awk \
    -v v_TOOLS_MOUNT="$TOOLS_MOUNT" \
    -v v_TINYOS_REL="$TINYOS_REL" \
    -v v_ESP_MOUNT="$ESP_MOUNT" \
    -v v_ESP_HINT="$ESP_HINT" \
    -v v_TOOLS_HINT="$TOOLS_HINT" \
    -v v_INSTALL_NAME="$INSTALL_NAME" \
    'BEGIN{
      if (length(v_TOOLS_MOUNT))  managed["TOOLS_MOUNT"]=v_TOOLS_MOUNT
      if (length(v_TINYOS_REL))   managed["TINYOS_REL"]=v_TINYOS_REL
      if (length(v_ESP_MOUNT))    managed["ESP_MOUNT"]=v_ESP_MOUNT
      if (length(v_ESP_HINT))     managed["ESP_HINT"]=v_ESP_HINT
      if (length(v_TOOLS_HINT))   managed["TOOLS_HINT"]=v_TOOLS_HINT
      if (length(v_INSTALL_NAME)) managed["INSTALL_NAME"]=v_INSTALL_NAME
    }
    END{
      for (k in managed) print k "=" managed[k]
    }' </dev/null >"$tmp"
fi

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
log "Updated $TINYOS_CONF: TOOLS_MOUNT=$TOOLS_MOUNT TINYOS_REL=$TINYOS_REL${ESP_MOUNT:+ ESP_MOUNT=$ESP_MOUNT}${INSTALL_NAME:+ INSTALL_NAME=$INSTALL_NAME}"
