#!/bin/busybox sh
# TinyOS early userspace (initramfs). BusyBox static, devtmpfs + mdev.
# Goal: fast boot to a recovery shell for EFI tweaks (e.g., rEFInd config), no in-init editor.
# Handoff to BusyBox init by default.


# Bind stdin/stdout/stderr to the console early
exec </dev/console >/dev/console 2>&1
set -eu
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
export LANG=C LC_ALL=C

BB=/bin/busybox
link_bb() {
  if [ -h "$BB" ]; then
    "$BB" ln -snfb "$("$BB" readlink "$BB")" "$1" || true
  else
    "$BB" ln -snfb "$BB" "$1" || true
  fi
}

# Millisecond-ish uptime stamp like the kernel
_ts()   { "$BB" awk '{printf "[%10.6f]", $1}' /proc/uptime 2>/dev/null ||
          printf "[   .      ]"; }
msg()   { printf "%s %s %s\n" "$(_ts)" "[init]" "$*" >&2; }
log()   { { [ "${VERBOSE:0}" -eq 0 ] && [ "${QUIET:-0}" -gt 0 ]; } ||
          msg "$*"; }
panic() { msg 'ERROR:' "$*"; exec "$BB" setsid "$BB" cttyhack "$BB" sh; }
trap 'rc=$?; [ $rc -eq 0 ] || panic "init exited with status $rc";' EXIT
