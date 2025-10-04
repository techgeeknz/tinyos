#!/bin/busybox sh
msg 'Dropping to shell (type "exit" to resume boot)'
"$BB" setsid "$BB" cttyhack "$BB" sh

msg 'Handing off to BusyBox init (PID stays 1)'
link_bb /sbin/init
exec /sbin/init
panic "/sbin/init failed; dropping to shell"
