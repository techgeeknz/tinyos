#!/bin/busybox sh
# Config file: KEY=VALUE only (VALUE is stripped of leading/trailing
# whitespace, but is otherwise literal; blank lines and full-line comments
# are ignored; whitespace around = is ignored).
# Sanitize to a temp file that contains only `unset KEY` and `KEY='VALUE'`,
# then source it.
if [ -z "$CFG" ]; then
  log "skipping config overrides (disabled by commandline)"
elif [ ! -f "$CFG" ]; then
  log "skipping config overrides ($CFG file not found)"
else
  log "applying config overrides from $CFG"

  _TMP_CONF="/run/tinyos.conf"
  "$BB" awk -f - "$CFG" >"$_TMP_CONF" <<'AWK'
    {
      # Match key (stripped of whitespace) and entire RHS
      if match($0, /^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$/, m) {
        key = m[1]; val = m[2];
        # Strip whitespace from RHS
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val);
        if (val == "") { printf "unset %s\n", key; next }

        # Quote value for shell
        gsub(/'/, "'\\''", val)
        printf "export %s='%s'\n", key, val
      }
    }
    END {
      printf "\n"
    }
AWK

  # Source the sanitized config file
  . "$_TMP_CONF"
  unset _TMP_CONF
fi

# Normalize config-derived paths:
# - TOOLS_MOUNT: strip trailing /
# - TINYOS_REL : strip leading and trailing / (keep 'EFI/...', do not make it absolute)
# - ESP_MOUNT  : strip trailing /
TOOLS_MOUNT="$("$BB" realpath "${TOOLS_MOUNT%/}")"
TINYOS_REL="${TINYOS_REL#/}"
TINYOS_REL="${TINYOS_REL%/}"
ESP_MOUNT="$("$BB" realpath "${ESP_MOUNT%/}")"
