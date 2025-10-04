#!/bin/busybox sh
# finish setting up essential FSH directories
"$BB" rm -rf /tmp /mnt || true
"$BB" mkdir -p /tmp /mnt /run/lock /run/log || true
"$BB" chmod 1777 /tmp || true
"$BB" chmod 0755 /run /run/lock /run/log || true

# Finish setting up /dev
[ -d /dev/pts ] || { "$BB" rm -rf /dev/pts; "$BB" mkdir -p /dev/pts; }
"$BB" mountpoint -q /dev/pts || "$BB" mount -t devpts devpts /dev/pts || true
[ -e /dev/ptmx ] || "$BB" ln -s /dev/pts/ptmx /dev/ptmx || true
