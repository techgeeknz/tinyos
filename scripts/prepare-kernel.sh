#!/usr/bin/env bash
# prepare-kernel.sh — Pure configuration helper for the Linux kernel tree
# (edits .config directly; let olddefconfig normalize)
#
# TinyOS policy: all tuning is external (see config/kernel.fragment, etc.).
# This script only seeds .config, applies optional fragments, and finalizes deps.
#
# Usage:
#   ./prepare-kernel.sh [--fragment FILE]... [--baseline FILE] [--expect-frag FILE] [-v|--verbose] [--clean]
#
set -euo pipefail

DO_CLEAN=0
VERBOSE=0
FRAGMENTS=()
BASELINE=""
EXPECT_FRAG=""

usage() {
  cat <<'EOF'
Usage: prepare-kernel.sh [OPTIONS]

Options:
  --fragment FILE     Add a fragment file to apply (can be repeated)
  --baseline FILE     Copy baseline config before applying fragments
  --expect-frag FILE  Diff against expected fragment (if scripts/diffconfig exists)
  --clean             Run 'make mrproper' before configuration
  --verbose, -v       Increase logging (repeatable)
  -h, --help          Show this help text and exit

Environment:
  YES2MOD=1           Run 'yes "" | make yes2modconfig' (default: 1)
  MAKE=make           Override make command (default: make)

Notes:
  * Fragments are applied in order; later ones override earlier.
  * Baseline, if given, completely replaces any existing .config.
  * Expect-frag is for reporting only (never fatal).
EOF
}

log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[prepare-kernel] $*" >&2 || true; }
run(){ log "+ $*"; "$@"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --clean) DO_CLEAN=1; shift ;;
    --verbose|-v) VERBOSE=$((VERBOSE+1)); shift ;;
    --fragment) FRAGMENTS+=("$2"); shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --expect-frag) EXPECT_FRAG="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Must be run from kernel source root
if [[ ! -f Makefile || ! -d scripts ]]; then
  echo "ERROR: Run from the kernel source directory (need Makefile + scripts/)" >&2
  exit 1
fi

: "${MAKE:=make}"

# CLEAN if requested
[ $DO_CLEAN -eq 1 ] && run "$MAKE" mrproper

# Seed .config
if [ -n "$BASELINE" ]; then
  [ -f "$BASELINE" ] || { echo "ERROR: baseline not found: $BASELINE" >&2; exit 1; }
  run cp -f -- "$BASELINE" .config
elif [ ! -f .config ]; then
  run "$MAKE" defconfig
  # Optional: mass-modularize to keep initramfs small
  if [ "${YES2MOD:=1}" -eq 1 ] && command -v yes >/dev/null; then
    yes "" | "$MAKE" yes2modconfig || true
  fi
fi

# --- In-place .config editing helpers (more robust than scripts/config) --------------

# kk_set KEY VALUE
# VALUE may be: y | m | n | "string with spaces" | raw_token (e.g. 16, 0x10)
kk_set() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp .config.XXXXXX)"
  awk -v k="$key" -v v="$val" '
    BEGIN { updated = 0 }
    {
      # set-form: KEY=...
      i = index($0, "=")
      if (i > 0 && substr($0, 1, i-1) == k) {
        if (v == "n") {
          print "# " k " is not set"
        } else {
          print k "=" v
        }
        updated = 1
        next
      }
      # not-set form: "# KEY is not set"
      if (substr($0,1,2) == "# ") {
        rest = substr($0, 3)
        if (rest == k " is not set") {
          if (v == "n") {
            print "# " k " is not set"
          } else {
            print k "=" v
          }
          updated = 1
          next
        }
      }
      # passthrough
      print
    }
    END {
      if (!updated) {
        if (v == "n") {
          print "# " k " is not set"
        } else {
          print k "=" v
        }
      }
    }
  ' .config >"$tmp"
  mv -f -- "$tmp" .config
}

apply_frag_file(){
  local frag="$1" line key val
  [ -f "$frag" ] || { log "(skip fragment: missing $frag)"; return 0; }
  log "Applying fragment: $frag"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "") continue ;;
      \#\ CONFIG_*" is not set")
        key="${line#\# }"; key="${key% is not set}"
        kk_set "$key" "n"
        ;;
      CONFIG_*'='*)
        key="${line%%=*}"
        val="${line#*=}"
        # Leave quotes as-is so strings stay strings; y/m/n handled above
        kk_set "$key" "$val"
        ;;
      *) : ;; # ignore unrelated comments
    esac
  done <"$frag"
}

# Apply all fragments
for f in "${FRAGMENTS[@]}"; do
  apply_frag_file "$f"
done

# Finalize deps
yes "" | "$MAKE" olddefconfig || "$MAKE" olddefconfig

# Optional diff vs expected fragment
if [ -n "$EXPECT_FRAG" ] && [ -x scripts/diffconfig ] && [ -f "$EXPECT_FRAG" ]; then
  echo "[prepare-kernel] diff vs EXPECT_FRAG:" >&2
  scripts/diffconfig "$EXPECT_FRAG" .config || true
fi

log "Configuration complete. Run 'make all' in this tree (or from your top-level: make -C linux all)."
