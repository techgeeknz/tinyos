#!/usr/bin/env bash
# prepare-busybox.sh — Pure configuration helper for the BusyBox tree
#
# TinyOS policy: keep config policy in external fragments (config/busybox.conf.d/*).
# This script seeds .config (from --baseline or defconfig), applies one or more
# BusyBox .config-style fragments, and finalizes with oldconfig.
#
# Fragment line forms supported (BusyBox .config syntax):
#   CONFIG_FOO=y | CONFIG_BAR=m | CONFIG_BAZ=n | CONFIG_QUX="string"
#   # CONFIG_NAME is not set
#
# Usage:
#   ./prepare-busybox.sh [--fragment FILE]... [--baseline FILE] [-v|--verbose] [--clean]
#                        [--out FILE] [--make ARGS] [--expect-config FILE]
#
# Exit codes: 0 ok, 2 usage, 3 input missing, 4 apply/merge error
set -euo pipefail

VERBOSE=0
DO_CLEAN=0
FRAGMENTS=()
BASELINE=""
OUT_CFG=""
MAKE_ARGS=""
EXPECT_CFG=""

usage() {
  cat <<'EOF'
Usage: prepare-busybox.sh [OPTIONS]

Options:
  --fragment FILE       Add a .config-style fragment to apply (repeatable)
  --baseline FILE       Use FILE as starting .config (else `make defconfig`)
  --out FILE            Also write resulting .config to FILE
  --make ARGS           Extra arguments for make (e.g. "-j4 CROSS_COMPILE=x86_64-linux-musl-")
  --expect-config FILE  If given, show a unified diff vs FILE after finalize
  --clean               Run 'make distclean' before configuration
  --verbose, -v         Increase logging (repeatable)
  -h, --help            Show help and exit

Notes:
  * Run this script from the BusyBox source tree (must contain Makefile & Config.in).
  * Fragments are applied in order; later lines override earlier ones.
  * BusyBox lacks 'olddefconfig'; we finalize with 'yes "" | make oldconfig'.
EOF
}

log() { [ "${VERBOSE:-0}" -gt 0 ] && echo "[prepare-busybox] $*" >&2 || true; }
run() { log "+ $*"; "$@"; }
die() { echo "[prepare-busybox] $*" >&2; usage; exit 2; }
err() { echo "[prepare-busybox] ERROR: $*" >&2; exit 4; }

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --fragment)       FRAGMENTS+=("${2:?}"); shift 2 ;;
    --baseline)       BASELINE="${2:?}"; shift 2 ;;
    --out)            OUT_CFG="${2:?}"; shift 2 ;;
    --make)           MAKE_ARGS="${2:?}"; shift 2 ;;
    --expect-config)  EXPECT_CFG="${2:?}"; shift 2 ;;
    --clean)          DO_CLEAN=1; shift ;;
    -v|--verbose)     VERBOSE=$((VERBOSE+1)); shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "Unknown arg: $1" ;;
  esac
done

# Must be run in BusyBox tree
if [[ ! -f Makefile || ! -f Config.in ]]; then
  echo "[prepare-busybox] ERROR: Run from the BusyBox source directory (need Makefile + Config.in)" >&2
  exit 3
fi

# Validate inputs
for f in "${FRAGMENTS[@]}"; do
  [ -f "$f" ] || { echo "[prepare-busybox] ERROR: fragment not found: $f" >&2; exit 3; }
done
if [ -n "$BASELINE" ] && [ ! -f "$BASELINE" ]; then
  echo "[prepare-busybox] ERROR: baseline not found: $BASELINE" >&2
  exit 3
fi

: "${MAKE:=make}"

# Optional clean
[ $DO_CLEAN -eq 1 ] && run "$MAKE" distclean

# Seed .config
if [ -n "$BASELINE" ]; then
  run cp -f -- "$BASELINE" .config
  log "Seeded from baseline: $BASELINE"
elif [ ! -f .config ]; then
  run "$MAKE" defconfig $MAKE_ARGS
  log "Seeded from defconfig"
else
  log "Using existing .config as seed"
fi

# --- Helpers to apply fragment lines to .config -----------------------------

# bb_set_kv KEY VALUE  (regex-safe, pure string comparisons)
# VALUE forms: y|m|n|"string"|raw_token — VALUE is written verbatim (except 'n' → “not set” form)
bb_set_kv() {
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

# apply_one_fragment FILE
apply_one_fragment() {
  local frag="$1" line key val
  [ -f "$frag" ] || { log "(skip fragment: missing $frag)"; return 0; }
  log "Applying fragment: $frag"

  # Read line-by-line, accept BusyBox .config syntax
  #   CONFIG_FOO=...     → set
  #   # CONFIG_FOO is not set  → set to n
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip blanks and comments that aren't "not set"
    case "$line" in
      "") continue ;;
      \#\ CONFIG_*" is not set")
          key="${line#\# }"; key="${key% is not set}"
          bb_set_kv "$key" "n"
          ;;
      CONFIG_*'='*)
          key="${line%%=*}"
          val="${line#*=}"
          # Keep quoted strings intact; normalize bare y/m/n tokens
          case "$val" in
            y|m|n|\"*\"|\'*\') ;;  # already well-formed
            *) : ;;                # numeric or other raw tokens are fine
          esac
          bb_set_kv "$key" "$val"
          ;;
      *) : ;;  # ignore other comments / garbage
    esac
  done <"$frag"
}

# Apply fragments in order; later wins
for f in "${FRAGMENTS[@]}"; do
  apply_one_fragment "$f"
done

# Finalize dependencies: BusyBox only has oldconfig
if command -v yes >/dev/null 2>&1; then
  LC_ALL=C yes "" | run "$MAKE" oldconfig $MAKE_ARGS || true
else
  # Fallback: run oldconfig non-interactively as best-effort
  run "$MAKE" oldconfig $MAKE_ARGS || true
fi

# Optionally write merged .config to OUT_CFG
if [ -n "$OUT_CFG" ] && [ "$(realpath "$OUT_CFG")" != "$(realpath .config)" ]; then
  mkdir -p "$(dirname "$OUT_CFG")"
  cp -f .config "$OUT_CFG"
  log "Wrote finalized config → $OUT_CFG"
fi

# Optional diff vs expected final config for diagnostics
if [ -n "$EXPECT_CFG" ] && [ -f "$EXPECT_CFG" ]; then
  if ! diff -u --label expected --label final "$EXPECT_CFG" .config >/dev/null 2>&1; then
    echo "[prepare-busybox] NOTE: final .config differs from EXPECT_CFG:" >&2
    diff -u --label expected --label final "$EXPECT_CFG" .config || true
  else
    log "Final .config matches EXPECT_CFG"
  fi
fi

log "BusyBox configuration complete. Next: make $MAKE_ARGS && make CONFIG_PREFIX=/path/to/stage install"
