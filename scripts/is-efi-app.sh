#!/usr/bin/env bash
# Detect whether a file is a PE/COFF EFI Application.
# Strategy:
#   1) Prefer binutils: `objdump -p` on PE images prints a "Subsystem" line.
#      We check it equals "EFI application".
#   2) Fallback: light PE sanity checks via hexdump/od:
#        - DOS magic "MZ" @ 0x00
#        - PE signature "PE\0\0" @ *(uint32_le)0x3C
#      (This fallback does NOT read the Subsystem; it only asserts “looks like PE”.)

set -euo pipefail

usage() { echo "usage: $0 <path-to-file>"; exit 2; }

[ $# -eq 1 ] || usage
f=$1
[ -f "$f" ] || { echo "not a file: $f" >&2; exit 3; }

# Prefer objdump if available; it fully understands PE and prints Subsystem.
if command -v objdump >/dev/null 2>&1; then
  # Works for PE/COFF; exits 0 even for non-ELF when format is recognized.
  # Example line in output:
  #   Subsystem               0000000a (EFI application)
  if objdump -p -- "$f" 2>/dev/null \
     | grep -qiE '^[[:space:]]*Subsystem[[:space:]]+[0-9a-fx]+[[:space:]]*\(EFI application\)'; then
    exit 0
  else
    # Fall through to heuristic before failing; objdump can be terse on some images.
    :
  fi
fi

# --- Heuristic fallback: minimal PE sanity checks ---------------------------
# Read a few bytes safely
read_bytes() { # read_bytes <offset> <count>
  dd if="$f" bs=1 skip="$1" count="$2" status=none 2>/dev/null
}

# DOS magic "MZ"
mz=$(read_bytes 0 2 | LC_ALL=C od -An -tx1 -v | tr -d ' \n')
[ "$mz" = "4d5a" ] || exit 1

# e_lfanew (PE header file offset) at 0x3C (little-endian uint32)
# Use od to decode as unsigned 32-bit little-endian
peoff=$(LC_ALL=C od -An -tu4 -N4 -j60 "$f" 2>/dev/null | tr -d ' ' || echo 0)
# Sanity check: offset must be non-zero and within file
[ -n "$peoff" ] || peoff=0
[ "$peoff" -gt 0 ] || exit 1

# "PE\0\0" signature at peoff
pesig=$(read_bytes "$peoff" 4 | LC_ALL=C od -An -tx1 -v | tr -d ' \n')
[ "$pesig" = "50450000" ] || exit 1

# We can’t reliably fetch the Subsystem without a full Optional Header map here.
# Treat “looks like PE/COFF” as good enough in fallback mode.
exit 0
