#!/bin/busybox sh
# -------- sysfs helpers --------
set_sysfs() { # set_sysfs <abs-or-rel-path-under-/sys> <value>
  p="$1"; v="$2"
  # 1) Normalize to an absolute path under /sys
  case "$p" in
    /sys/*) abs="$p" ;;
    /*)     log "sysfs: reject absolute path outside /sys: '$p'"; return 1 ;;
    *)      abs="/sys/${p#/}" ;;
  esac
  # 2) Cheap traversal guard even without canonicalization
  case "$abs" in *"/.."*|*"../"*) log "sysfs: reject path with '..': '${abs#/sys/}'"; return 1 ;; esac
  # 3) Canonicalize with BusyBox readlink (if it resolves, enforce /sys prefix)
  rp="$("$BB" readlink -f -- "$abs" 2>/dev/null || true)"
  if [ -n "$rp" ]; then
    case "$rp" in /sys/*) abs="$rp" ;; *) log "sysfs: canonical path escapes /sys: '$rp'"; return 1 ;; esac
  fi
  # 4) Write if writable
  if [ -w "$abs" ]; then
    printf '%s' "$v" >"$abs" 2>/dev/null && { log "sysfs: set ${abs#/sys/}='$v'"; return 0; }
  fi
  log "sysfs: cannot set ${abs#/sys/} (not writable?)"; return 1
}
apply_sysfs_dir() { # apply_sysfs_dir <dir> ; *.conf "path = value", comments/# ok
  d="$1"; [ -d "$d" ] || return 0
  log "applying sysfs tweaks from $d"
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in \#*|'') continue;;
        *=*) k="${line%%=*}"; v="${line#*=}";;
        *) continue;;
      esac
      k="$(printf '%s' "$k" | "$BB" sed -r 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      v="$(printf '%s' "$v" | "$BB" sed -r 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      # Warn if an absolute path is not under /sys (it will be rejected by set_sysfs anyway)
      case "$k" in /sys/*) : ;; /*) log "sysfs: warning: absolute path not under /sys: '$k'";; esac
      [ -n "$k" ] && set_sysfs "$k" "$v" || true
    done <"$f"
  done
}

# --- Apply initramfs sysfs.d early (before any external mounts) ---
apply_sysfs_dir "/etc/sysfs.d"
