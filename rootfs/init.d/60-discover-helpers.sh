#!/bin/busybox sh
# Given blkid output on stdin, filter by the given key (BusyBox-safe, concise)
# Usage examples:
#   blkid | filter_hint 'LABEL=HP_TOOLS'
#   blkid | filter_hint 'LABEL="ESP SYSTEM"'
#   blkid | filter_hint 'TYPE~/^(vfat|fat|msdos)$/'
#   blkid | filter_hint '/dev/sda1'
filter_hint() {
  "$BB" awk -v hint="$1" -v FS=':' '
    BEGIN {
      if (hint ~ /^[/]dev[/][^:]+$/)             { mode="dev"; hval=hint }
      else if (match(hint, /^([A-Z_]+)([=~].*)$/, kr)) {
        hkey=kr[1]; raw=kr[2]
        if      (match(raw, /^~[/](.*)[/]$/, r)) { mode="re";  hval=r[1] }
        else if (match(raw, /^~(.*)$/, r))       { mode="re";  hval=r[1] }
        else if (match(raw, /^=["](.*)["]$/, r)) { mode="str"; hval=r[1] }
        else if (match(raw, /^=(.*)$/, r))       { mode="str"; hval=r[1] }
      } else exit 2
    }
    (mode=="dev" && $1==hval) { print }
    (mode!="dev" && match($0, FS)) {
      kvs=substr($0, RSTART+RLENGTH);
      while (match(kvs, /[[:space:]]+([A-Z_]+)="([^"]*)"/, kv)) {
        if (kv[1]==hkey && (
            (mode=="re" && kv[2] ~ hval) || (kv[2]==hval)
        )) { print; next }
        kvs=substr(kvs, RSTART+RLENGTH)
      }
    }'
}

# Resolve a device from a "hint" (LABEL=…, UUID=…, TYPE=…, or /dev/…)
resolve_hint() {
  "$BB" blkid | filter_hint "$1" | "$BB" awk -v FS=':' 'NR==1{print $1}'
}

mount_fat_ro() {  # $1:dev $2:mountpoint
  dev="$1"; mnt="$2"
  "$BB" mount -t vfat -o ro,nodev,nosuid,noexec "$dev" "$mnt" 2>/dev/null \
  || "$BB" mount -t vfat -o ro "$dev" "$mnt" 2>/dev/null || return 1
}

VFAT_PARTS=
filter_vfat() { echo -n "$VFAT_PARTS" | filter_hint "$1" || true; }
