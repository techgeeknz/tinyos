#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# stage-efi.sh — Build the TinyOS EFI image into the staging directory
#
# What this does (aligned with current project decisions):
#   - Takes a kernel bzImage (EFI-stubbed) and **embeds the primary initramfs**.
#   - Does **NOT** embed a fallback/minirescue initramfs.
#   - Does **NOT** embed a cmdline by default; opt-in via --embed-cmdline/--cmdline.
#   - Writes the resulting EFI binary into the **staging/payload** directory (flat).
#
# Typical use (from the Makefile):
#   stage-efi.sh \
#     --payload-root staging/payload \
#     --tinyos-efi   linux/arch/x86/boot/bzImage \
#     --initramfs    staging/initramfs.img \
#     [--out-name    tinyos.efi]
#   # Output: "$PAYLOAD_ROOT/<out-name>" (default: tinyos.efi)
#
# Optional extras:
#   --embed-cmdline /path/to/cmdline.txt   # embed exact cmdline
#   --cmdline "console=tty0 ..."            # embed inline cmdline
#
# Env overrides (optional):
#   OBJCOPY – path to (llvm-)objcopy (auto-detected)
#   VERBOSE – >0 for verbose logging (additive with -v)
#
# Notes:
#   - rEFInd can override the embedded initramfs via its own `initrd` line.
#   - We avoid touching HP_TOOLS here; `sudo make install` handles deployment.
#   - rEFInd stanza generation is handled by the install script/Makefile.
# ------------------------------------------------------------------------------

# Find project root (dirname trick)
SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

# Defaults
PAYLOAD_ROOT=""
OUT=""
OUT_NAME="tinyos.efi"
OBJCOPY=${OBJCOPY:-$(command -v llvm-objcopy || command -v objcopy || true)}
VERBOSE=${VERBOSE:-0}

log(){ [ "${VERBOSE:-0}" -gt 0 ] && echo "[stage-efi] $*" >&2 || true; }
die(){ echo "[stage-efi] ERROR: $*" >&2; exit 1; }

# Args
KERNEL= INITRD= EMBED_CMDLINE=0 CMDLINE_STR="" CMDLINE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --payload-root)  PAYLOAD_ROOT="${2:?}"; shift 2 ;;
    --tinyos-efi)    KERNEL="${2:?}"; shift 2 ;;
    --initramfs)     INITRD="${2:?}"; shift 2 ;;
    --out-name)      OUT_NAME="${2:?}"; shift 2 ;;
    --embed-cmdline) EMBED_CMDLINE=1; CMDLINE_FILE="${2:?}"; shift 2 ;;
    --cmdline)       EMBED_CMDLINE=1; CMDLINE_STR="${2:?}"; shift 2 ;;
    -v|--verbose)    VERBOSE=$((VERBOSE+1)); shift ;;
    -h|--help)       SHOW_HELP=1; shift ;;
    *) echo "Unknown arg: $1" >&2; SHOW_HELP=1; shift ;;
  esac
done

if [ "${SHOW_HELP:-0}" -eq 1 ]; then
  sed -n '1,160p' "$0" | sed -n '1,/^# ------------------------------------------------------------------------------$/p'
  exit 2
fi

# Validate
[ -n "$PAYLOAD_ROOT" ] || die "--payload-root is required"
[ -n "$KERNEL" ] || die "--tinyos-efi is required"
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
[ -n "$INITRD" ] || die "--initramfs is required"
[ -f "$INITRD" ] || die "initramfs not found: $INITRD"
[ -n "$OBJCOPY" ] || die "objcopy not found (install binutils/llvm)"

OUT="$PAYLOAD_ROOT/$OUT_NAME"
mkdir -p "$PAYLOAD_ROOT"

# Scratch
TMPDIR=$(mktemp -d)
cleanup(){ rm -rf "$TMPDIR"; }
trap cleanup EXIT INT TERM

# Prepare optional cmdline
if [ "$EMBED_CMDLINE" = 1 ]; then
  if [ -n "$CMDLINE_FILE" ]; then
    [ -f "$CMDLINE_FILE" ] || die "cmdline file not found: $CMDLINE_FILE"
    tr -d '\n' < "$CMDLINE_FILE" > "$TMPDIR/cmdline.txt"
  else
    printf '%s\n' "$CMDLINE_STR" > "$TMPDIR/cmdline.txt"
  fi
fi

# Build EFI: copy kernel → OUT, add .initrd (and optionally .cmdline)
log "Copying kernel to $OUT"
cp -f "$KERNEL" "$OUT"

log "Embedding initramfs: $INITRD"
"$OBJCOPY" \
  --add-section .initrd="$INITRD" \
  --set-section-flags .initrd=contents,alloc,load,readonly,data \
  "$OUT"

if [ "$EMBED_CMDLINE" = 1 ]; then
  log "Embedding cmdline from $([ -n "$CMDLINE_FILE" ] && echo "$CMDLINE_FILE" || echo "inline string")"
  "$OBJCOPY" \
    --add-section .cmdline="$TMPDIR/cmdline.txt" \
    --set-section-flags .cmdline=contents,alloc,load,readonly,data \
    "$OUT"
fi

[ -s "$OUT" ] || die "objcopy failed to produce $OUT"

echo "EFI image staged: $OUT"
