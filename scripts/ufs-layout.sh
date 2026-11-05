#!/bin/sh
# Read-only storage survey for Nothing Phone (3a) Pro (A059P).
#
# Run it from the postmarketOS initramfs debug shell (append pmos.debug-shell
# to the cmdline) or from any Alpine userspace booted on the device:
#
#     sh ufs-layout.sh > /tmp/layout.txt
#
# It only reads /sys, blkid and dd's the first 4 KiB of each whole disk. It
# writes nothing, formats nothing and mounts nothing. Feed the output to
# rootfs-plan.sh on your build host to get the deviceinfo/cmdline lines.

set -u

say() { printf '%s\n' "$*"; }

say "# A059P storage survey"
say "# kernel=$(uname -r) host=$(uname -n)"
say "#"

found=0
for sysdev in /sys/class/block/*; do
	[ -e "$sysdev" ] || continue

	name=${sysdev##*/}
	case "$name" in
	sd*) ;;
	*) continue ;;
	esac

	# Skip partitions here, whole disks are the directories that contain
	# sibling entries named after themselves.
	[ -e "$sysdev/partition" ] && continue

	dev="/dev/$name"
	[ -b "$dev" ] || continue
	found=$((found + 1))

	sectors=$(cat "$sysdev/size" 2>/dev/null || echo 0)
	bsize=$(cat "$sysdev/queue/logical_block_size" 2>/dev/null || echo "?")
	pbsize=$(cat "$sysdev/queue/physical_block_size" 2>/dev/null || echo "?")
	model=$(cat "$sysdev/device/model" 2>/dev/null | tr -s ' ')
	rot=$(cat "$sysdev/queue/rotational" 2>/dev/null || echo "?")

	say "disk=$dev sectors=$sectors logical_block=$bsize physical_block=$pbsize rotational=$rot model=[${model:-unknown}]"

	# Android super partition carries LP metadata right at the start.
	if [ "$(dd if="$dev" bs=4096 count=1 2>/dev/null | strings | grep -c LP_METADATA_GEOMETRY_MAGIC)" -gt 0 ]; then
		say "  lp_metadata=yes"
	else
		say "  lp_metadata=no"
	fi

	for part in "$sysdev/$name"*; do
		[ -e "$part" ] || continue
		pname=${part##*/}
		pdev="/dev/$pname"
		[ -b "$pdev" ] || continue

		psectors=$(cat "$part/size" 2>/dev/null || echo 0)
		pstart=$(cat "$part/start" 2>/dev/null || echo 0)
		id=$(blkid "$pdev" 2>/dev/null || true)

		fstype=$(printf '%s' "$id" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')
		flabel=$(printf '%s' "$id" | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p')
		plabel=$(printf '%s' "$id" | sed -n 's/.*PARTLABEL="\([^"]*\)".*/\1/p')
		uuid=$(printf '%s' "$id" | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')

		say "  part=$pdev start=$pstart sectors=$psectors fstype=${fstype:-none} label=${flabel:-none} partlabel=${plabel:-none} uuid=${uuid:-none}"
	done
	say ""
done

if [ "$found" -eq 0 ]; then
	say "# No /dev/sd* devices. Either this is not the UFS host (check"
	say "# 'dmesg | grep -i ufs'), or CONFIG_SCSI_UFS_QCOM did not probe."
	exit 1
fi

say "# Interpretation"
say "#   PARTLABEL values give the stock Android names (super, userdata, boot_a...)."
say "#   A partition with fstype=ext4 and label=pmOS_root is already a rootfs."
say "#   Next: copy this file off the device and run rootfs-plan.sh on the host."
