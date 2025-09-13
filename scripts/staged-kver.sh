#!/usr/bin/env bash
set -euo pipefail

ROOT=""       # path to .../lib/modules   (NOT .../<KVER>)
ONE=0
VERBOSE=${VERBOSE:-0}

die(){ echo "[staged-kver] ERROR: $*" >&2; exit 1; }
log(){ [ "$VERBOSE" -gt 0 ] && echo "[staged-kver] $*" >&2 || true; }

while [ $# -gt 0 ]; do
  case "$1" in
    --modules-root) ROOT=${2:?}; shift 2;;
    --one)          ONE=1; shift;;
    -v|--verbose)   VERBOSE=$((VERBOSE+1)); shift;;
    *) die "Unknown arg: $1";;
  esac
done

[ -n "$ROOT" ] || die "--modules-root is required"
[ -d "$ROOT" ] || die "not a directory: $ROOT"

mapfile -t ks < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
                  | while IFS= read -r k; do
                      [ -d "$ROOT/$k/kernel" ] && printf '%s\n' "$k"
                    done | sort -V)

case "${#ks[@]}" in
  0) die "no versioned module trees found under: $ROOT" ;;
  1) echo "${ks[0]}" ;;
  *) [ "$ONE" -eq 1 ] && die "multiple KVERs present: ${ks[*]}" || printf '%s\n' "${ks[@]}" ;;
esac
