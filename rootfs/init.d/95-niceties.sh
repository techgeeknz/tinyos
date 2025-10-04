#!/bin/busybox sh
# Optional niceties (ignore failures)
"$BB" modprobe hp_wmi     2>/dev/null || true
"$BB" modprobe lis3lv02d  2>/dev/null || true
"$BB" modprobe rfkill     2>/dev/null || true
