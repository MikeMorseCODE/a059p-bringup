#!/bin/busybox ash
# Fixture: second stage, which is where the rootfs is looked for.
. ./init_functions.sh
fail_halt_boot
echo "Switching root"
