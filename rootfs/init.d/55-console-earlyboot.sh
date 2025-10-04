#!/bin/busybox sh
# Brute-force load all initramfs modules (temporary workaround for console)
KVER="$("$BB" uname -r)"
"$BB" find "/lib/modules/$KVER/" -name '*.ko*' -print0 | "$BB" xargs -r0 modprobe || true
