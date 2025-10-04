#!/bin/busybox sh
# --- Kernel cmdline (for feature toggles) ---
CFG=/etc/tinyos.conf
_CMD_TOOLS_HINT=
_CMD_ESP_HINT=
CMDLINE="$("$BB" cat /proc/cmdline 2>/dev/null || true)"

for tok in $CMDLINE; do
  case "$tok" in
    quiet|tinyos.quiet)
      export QUIET=1 ;;
    tinyos.debug|tinyos.trace)
      export VERBOSE=1 QUIET=0
      # Pretty xtrace with kernel-like timestamp + line number
      export PS4='+$(_ts) ${LINENO}: '
      set -eux  # enable xtrace too
      # Optional: crank printk so kernel messages are visible
      echo "7 4 1 7" >/proc/sys/kernel/printk 2>/dev/null || true
      log "debug tracing enabled via kernel cmdline"
      ;;
    tinyos.noconf)
      # Disable tinyos.conf parsing
      CFG="" ;;
    tinyos.tools=*)
      # Override hint for TOOLS partition
      _CMD_TOOLS_HINT="${tok#tinyos.tools=}" ;;
    tinyos.esp=*)
      # Override hint for ESP partition
      _CMD_ESP_HINT="${tok#tinyos.esp=}" ;;
    *) ;;
  esac
done

if [ "$QUIET" -eq 0 ] && [ "$VERBOSE" -eq 0 ]; then
  # Quiet the kernel a touch (best-effort)
  echo 3 4 1 3 > /proc/sys/kernel/printk 2>/dev/null || true
fi
