#!/usr/bin/env bash
# merge-busybox-config.sh — Layer one or more fragments over a base BusyBox defconfig
#
# Why: Keep your uploaded BusyBox defconfig as the **base**, then layer small,
# project-specific fragments to avoid churn. This script performs a deterministic
# merge (overlay wins), writes the result to the BusyBox tree as .config, and
# then runs `oldconfig` non-interactively (piping defaults).
#
# Features
# - Order-stable output (sorted by CONFIG key)
# - Supports y/m/n and value-style options (e.g., CONFIG_FOO="bar")
# - Accepts multiple --fragment arguments; later ones override earlier ones
# - Optional stripping of noisy toolchain keys via --strip REGEX
# - Portable: avoids GNU awk-only features (no asort)
#
# Usage
#   ./merge-busybox-config.sh \
#       --busybox-tree   ../busybox \
#       --base           ./busybox.defconfig.uploaded \
#       --fragment       ./busybox.fragment \
#       --fragment       ./site.override.fragment \
#       [--out           ./out/busybox.merged.config] \
#       [--make          "-j$(nproc)" ] \
#       [--strip         "CONFIG_(CROSS_COMPILER_PREFIX|SYSROOT|EXTRA_.*)"]
#
# Typical flow in this project
#   1) Keep your uploaded defconfig as the base (busybox.defconfig)
#   2) Add tiny overlays in one or more fragments
#   3) Call this script from the Makefile before building BusyBox
#
# Example fragment (busybox.fragment):
#   CONFIG_STATIC=y
#   CONFIG_FEATURE_INSTALLER=y
#   CONFIG_SWITCH_ROOT=y
#   # Disable explicitly:
#   # CONFIG_SELINUX is not set
#
# Exit codes: 0 ok, 2 usage, 3/4 input/merge errors
set -euo pipefail

BB_TREE=""
BASE_CFG=""
FRAG_CFGS=()   # repeatable
OUT_CFG=""
MAKE_ARGS=""
STRIP_RE='CONFIG_(CROSS_COMPILER_PREFIX|SYSROOT|EXTRA_.*)'

_err(){ printf '%s\n' "[merge-busybox-config] ERROR: $*" >&2; exit 4; }
_die(){ printf '%s\n' "[merge-busybox-config] $*" >&2; exit 2; }
_log(){ printf '%s\n' "[merge-busybox-config] $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --busybox-tree) BB_TREE="$2"; shift 2;;
    --base)         BASE_CFG="$2"; shift 2;;
    --fragment)     FRAG_CFGS+=("$2"); shift 2;;
    --out)          OUT_CFG="$2"; shift 2;;
    --make)         MAKE_ARGS="$2"; shift 2;;
    --strip)        STRIP_RE="$2"; shift 2;;
    -h|--help)      sed -n '1,120p' "$0"; exit 0;;
    *) _die "Unknown arg: $1";;
  esac
done

[ -n "${BB_TREE}" ] || _die "--busybox-tree required"
[ -n "${BASE_CFG}" ] || _die "--base required"
[ "${#FRAG_CFGS[@]}" -gt 0 ] || _die "--fragment required (repeatable)"
[ -d "${BB_TREE}" ] || _err "BusyBox tree not found: ${BB_TREE}"
[ -f "${BASE_CFG}" ] || _err "Base config not found: ${BASE_CFG}"
for f in "${FRAG_CFGS[@]}"; do [ -f "$f" ] || _err "Fragment not found: $f"; done

TMPDIR=${TMPDIR:-/tmp}
MERGED=$(mktemp "${TMPDIR%/}/bbmerge.XXXXXX")
BASE_PAIRS=$(mktemp "${TMPDIR%/}/bbbase.XXXXXX")
FRAG_PAIRS=$(mktemp "${TMPDIR%/}/bbfrag.XXXXXX")
trap 'rm -f "${MERGED}" "${BASE_PAIRS}" "${FRAG_PAIRS}"' EXIT

# Normalize one config to key<TAB>value lines.
# - value "# n" means "not set"
norm_cfg() {
  awk '
    function is_kv(l){ return (l ~ /^CONFIG_[A-Z0-9_]+(=|\s+is not set)/) }
    function key(l){ sub(/=.*/,"",l); sub(/\s+.*/,"",l); return l }
    function val(l){ if (l ~ / is not set$/) return "# n"; sub(/^[^=]*=/,"",l); return l }
    { if (is_kv($0)) print key($0) "\t" val($0) }
  ' "$1"
}

# Produce base pairs (optionally strip patterns)
norm_cfg "${BASE_CFG}" | awk -v re="${STRIP_RE}" 're!="" && $1 ~ re {next} {print}' > "${BASE_PAIRS}"

# Produce overlay pairs from all fragments (last one wins), with same stripping
: > "${FRAG_PAIRS}"
for f in "${FRAG_CFGS[@]}"; do
  norm_cfg "$f" | awk -v re="${STRIP_RE}" 're!="" && $1 ~ re {next} {print}' >> "${FRAG_PAIRS}"
done

# Merge: sort by key then by source order (base first, overlays after), keep LAST
# Then render to BusyBox syntax and sort lexicographically by key for stable output.
{ awk '{print $0 "\t0"}' "${BASE_PAIRS}"; awk '{print $0 "\t1"}' "${FRAG_PAIRS}"; } \
 | sort -t $'\t' -k1,1 -k3,3n \
 | awk -F '\t' '{
     k=$1; v=$2;
     if (prev!="" && k!=prev){ out[prev]=val; }
     prev=k; val=v;
   } END{ if (prev!="") out[prev]=val; for (k in out) print k "\t" out[k]; }' \
 | sort -t $'\t' -k1,1 \
 | awk -F '\t' '{ if ($2=="# n") print "# " $1 " is not set"; else print $1 "=" $2 }' \
 > "${MERGED}"

# Optional: write merged config to a path for inspection
if [ -n "${OUT_CFG}" ]; then
  mkdir -p "$(dirname "${OUT_CFG}")"
  cp -f "${MERGED}" "${OUT_CFG}"
  _log "Wrote merged config → ${OUT_CFG}"
fi

# Install into BusyBox tree and refresh (non-interactive)
cp -f "${MERGED}" "${BB_TREE}/.config"
_log "Installed merged config → ${BB_TREE}/.config"
(
  cd "${BB_TREE}"
  # BusyBox doesn't have olddefconfig; use oldconfig with default answers.
  LC_ALL=C yes "" | make oldconfig ${MAKE_ARGS}
)

_log "Done. You can now: make -C ${BB_TREE} ${MAKE_ARGS} && make -C ${BB_TREE} CONFIG_PREFIX=... install"
