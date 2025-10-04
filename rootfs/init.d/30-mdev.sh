#!/bin/busybox sh
# Bring up mdev for /dev population and hotplug handling
if [ -e /sbin/mdev ]; then
  log "Starting mdev daemon"
  link_bb /sbin/mdev
  echo /sbin/mdev > /proc/sys/kernel/hotplug || true
  /sbin/mdev -s
fi
