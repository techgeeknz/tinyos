#!/bin/busybox sh
# Pseudo-fs (idempotent)
mnt_pfs() { "$BB" mount -t "$1" "$2" "$3" || panic "mnt_pfs: mount $3 failed"; }
"$BB" mkdir -p /proc /sys /dev
mnt_pfs proc     proc     /proc
mnt_pfs sysfs    sysfs    /sys
mnt_pfs devtmpfs devtmpfs /dev
"$BB" rm -rf /run 2>/dev/null || true; "$BB" mkdir -p /run || true
if "$BB" ln -snf /proc/$$/exe /run/busybox; then
  BB=/run/busybox
fi
