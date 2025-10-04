#!/bin/busybox sh
# ---------- Bind in external modules/firmware from TOOLS ----------

# Modules: bind only if directory appears to contain supplemental assets, ignore otherwise
MOD_EXT="$TINYOS_DIR/lib/modules/$KVER"
if [ -d "$MOD_EXT" ] && \
   "$BB" find "$MOD_EXT" \
     -type f \( -name '*.ko' -o -name '*.ko.*' -o -name 'modules.dep*' -o -name 'modules.*' \) \
     -print 2>/dev/null | "$BB" head -n1 >/dev/null; then
  log "mounting kernel modules payload"
  "$BB" mkdir -p "/lib/modules/$KVER"
  "$BB" mountpoint -q "/lib/modules/$KVER" || "$BB" mount --bind "$MOD_EXT" "/lib/modules/$KVER" 2>/dev/null || true
fi

# Firmware: bind (and set runtime search path) only if non-empty and no cmdline override
FW_EXT="$TINYOS_DIR/lib/firmware"
if [ -d "$FW_EXT" ] && \
   "$BB" find "$FW_EXT" -type f -print 2>/dev/null | "$BB" head -n1 >/dev/null; then
  if ! printf '%s' "$CMDLINE" | "$BB" tr ' ' '\n' | "$BB" grep -q '^firmware_class.path='; then
    log "mounting kernel firmware payload"
    "$BB" mkdir -p /lib/firmware
    "$BB" mountpoint -q /lib/firmware || "$BB" mount --bind "$FW_EXT" /lib/firmware 2>/dev/null || true
    set_sysfs "/sys/module/firmware_class/parameters/path" "/lib/firmware" || true
  else
   msg "not mounting kernel firmware payload, search path overridden by kernel cmdline"
  fi
fi
