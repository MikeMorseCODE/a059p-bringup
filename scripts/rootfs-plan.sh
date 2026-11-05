#!/bin/sh
# Turn a ufs-layout.sh dump into the exact postmarketOS settings.
#
#     sh rootfs-plan.sh layout.txt
#
# Emits three things, in the order you need them:
#   1. mkfs/mount commands to put a rootfs on the device
#   2. the deviceinfo lines for the device package
#   3. the optional kernel cmdline line
#
# Nothing here talks to the phone; it only formats the plan.

set -u

DUMP=${1:-}
[ -n "$DUMP" ] && [ -r "$DUMP" ] || { echo "usage: $0 <layout.txt>"; exit 2; }

say() { printf '%s\n' "$*"; }

# Pull fields out of the survey.
disk=$(sed -n 's/^disk=\([^ ]*\).*/\1/p' "$DUMP" | head -n1)
sector=$(sed -n 's/^disk=.*logical_block=\([0-9?]*\).*/\1/p' "$DUMP" | head -n1)
lpmeta=$(sed -n 's/^  lp_metadata=\(.*\)$/\1/p' "$DUMP" | head -n1)
userdata=$(sed -n 's/^  part=\([^ ]*\).*partlabel=userdata.*$/\1/p' "$DUMP" | head -n1)
superdev=$(sed -n 's/^  part=\([^ ]*\).*partlabel=super.*$/\1/p' "$DUMP" | head -n1)
superdev=${superdev:-$userdata}

say "# Plan for ${disk:-unknown-disk} (logical block size ${sector:-unknown})"
say ""

if [ -z "$disk" ]; then
	say "# ERROR: no 'disk=' line in $DUMP; the survey did not find a UFS disk."
	exit 1
fi

if [ "${sector:-}" != "4096" ]; then
	say "# WARNING: logical block size is ${sector:-unknown}, expected 4096."
	say "#          deviceinfo_rootfs_image_sector_size must match it or the"
	say "#          image will be written with the wrong layout."
	say ""
fi

say "## Layout A - rootfs directly on the userdata partition"
say "#   Simplest, survives nothing else, and keeps super untouched."
if [ -n "$userdata" ]; then
	say "#   Target: $userdata"
	say "mkfs.ext4 -L pmOS_root -b 4096 $userdata"
	say "mount $userdata /mnt"
	say "# copy the pmOS rootfs tree in, then:"
	say "umount /mnt"
	say ""
	say "# deviceinfo: nothing extra needed, the label is what the initramfs looks for."
else
	say "#   No partition has PARTLABEL=userdata - check the survey output."
	say ""
fi

say "## Layout B - rootfs inside the dynamic super partition"
say "#   Use this when userdata must stay intact (A/B OTA slots, vendor data)."
say "#   make-dynpart-mappings has to exist in the initramfs for this."
if [ "$lpmeta" = "yes" ] && [ -n "$superdev" ]; then
	say "#   Target: $superdev (LP metadata present)"
	say "make-dynpart-mappings $superdev 0"
	say "mkfs.ext4 -L pmOS_root -b 4096 /dev/mapper/system_a"
	say ""
	say "# deviceinfo:"
	say "deviceinfo_super_partitions=\"$superdev\""
else
	say "#   No LP metadata was found on the super/userdata partition, so this"
	say "#   layout is not available. Stay with layout A."
fi
say ""

say "## Finding it again at boot"
say "#   postmarketOS mounts the rootfs it finds by filesystem label pmOS_root and"
say "#   by pmOS_boot for /boot, so with the label set above no root= is needed."
say "#   To pin a specific partition regardless of labels, add one line to"
say "#   kernel-cmdline.conf instead:"
say "#     pmos_root_uuid=<UUID printed by: blkid -s UUID -o value <partition>>"
say "#   Keep it commented out until the UUID is real: an unknown UUID makes the"
say "#   initramfs fail instead of falling back to the label search."
