#!/bin/busybox sh
# BusyBox self-install (foreground, critical)
# (We do this early so all applets are available.)
log "install busybox"
"$BB" [ ! -e /tbin ] || "$BB" rm -rf /tbin
"$BB" mkdir -p /tbin
"$BB" --install -s /tbin
"$BB" mv -nt /bin /tbin/* /tbin/.[!.]* /tbin/..?* || true
"$BB" rm -rf /tbin

# Enforce a unified /bin ( /sbin -> /bin preferred, but /bin -> /sbin okay)
[ -d /sbin ] || { [ ! -e /sbin ] || "$BB" rm -f /sbin; "$BB" ln -snf /bin /sbin; }
if [ "$("$BB" realpath /bin)" != "$("$BB" realpath /sbin)" ]; then
  log "unifying /sbin -> /bin"
  "$BB" mkdir -p /tbin
  "$BB" mv -ft /tbin /sbin/* /sbin/.[!.]* /sbin/..?* || true
  "$BB" mv -ft /tbin /bin/*  /bin/.[!.]*  /bin/..?*  || true
  "$BB" rm -rf /bin /sbin
  "$BB" mv -f  /tbin /bin
  "$BB" ln -snf /bin /sbin
fi
