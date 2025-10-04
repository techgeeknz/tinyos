#!/bin/busybox sh
# Core config (required for finding and mounting payload):
export TOOLS_MOUNT=/boot/tools
export ESP_MOUNT=/boot/efi
export TINYOS_REL="EFI/tinyos"
export TINYOS_TOKEN=

# Additional config knobs (optional):
#   TOOLS_HINT, ESP_HINT   : one of LABEL=…, UUID=…, TYPE=…, or /dev/…
export TOOLS_HINT=""
export ESP_HINT=""

# Manifest template for payload manifest discovery
MANIFEST_TEMPLATE="tinyos-{}.manifest"
subst_template() { # $1 template, $2 value
  echo "${1%\{\}*}$2${1#*\{\}}"
}
