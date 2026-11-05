#!/bin/sh
# Classify a boot that did not reach switch-root, from the initramfs debug
# shell or from a captured log.
#
#   sh diagnose-boot.sh                          # live system
#   sh diagnose-boot.sh --dmesg dmesg.txt --partitions parts.txt
#
# It answers one question: did UFS fail to come up, or did pmOS fail to find
# the rootfs on a disk that is fine? Those need completely different fixes and
# their symptoms overlap in the last few lines of the log.

set -u

DMESG=""
PARTS=""
while [ $# -gt 0 ]; do
	case "$1" in
	--dmesg) DMESG=$2; shift 2 ;;
	--partitions) PARTS=$2; shift 2 ;;
	-h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -z "$DMESG" ]; then
	DMESG=$tmp/dmesg
	dmesg >"$DMESG" 2>/dev/null || : >"$DMESG"
fi
[ -r "$DMESG" ] || { echo "cannot read $DMESG" >&2; exit 1; }
[ -n "$PARTS" ] || PARTS=/proc/partitions
[ -r "$PARTS" ] || PARTS=/dev/null

has() { grep -qiE "$1" "$DMESG"; }

echo "== evidence =="

has 'ufshcd' && echo "  ufs driver   : present" || echo "  ufs driver   : absent"
has 'ufshcd[^:]*: probed|ufshcd_pltfrm_init\(\) failed|ufshcd.*init.*failed' &&
	echo "  ufs probe    : see lines below" || echo "  ufs probe    : no probe line"
has 'ufs.*phy|qmp-ufs' && echo "  ufs phy      : mentioned" || echo "  ufs phy      : absent"
has 'scsi host[0-9]+: ufshcd|\[sda\]' && echo "  scsi disk    : present" || echo "  scsi disk    : absent"
has 'unable to mount root partition' && echo "  mount        : failed" || echo "  mount        : no failure logged"
has 'PMOS STAGE 1' && echo "  pmos stage 1 : ran" || echo "  pmos stage 1 : not in log"

parts=""
if [ -s "$PARTS" ]; then
	parts=$(awk 'NR>2 && $4 ~ /^sd/ {print $4}' "$PARTS" 2>/dev/null | tr '\n' ' ')
fi
echo "  partitions   : ${parts:-none}"

# Super/dynamic partition mapping shows up as /dev/mapper entries.
has 'make-dynpart-mappings|mapper/system' && echo "  dynpart      : attempted" || true

echo
echo "== ufs lines =="
grep -iE 'ufs|qmp' "$DMESG" | tail -15

echo
echo "== last root/mount lines =="
grep -iE 'root partition|switch root|switching root|mounting root|Detected .* filesystem|super partition' "$DMESG" | tail -10

echo
echo "== verdict =="

if ! has 'ufshcd'; then
	echo "  UFS DRIVER NEVER BOUND"
	echo "  NEXT: the controller node is not probing. Check the DTB has &ufs_mem_hc"
	echo "        status=okay and CONFIG_SCSI_UFS_QCOM=y. Boot the same payload"
	echo "        with the stock DTB to tell a DTS problem from a config problem."
	exit 10
fi

if has 'ufshcd_pltfrm_init\(\) failed|Failed to get PHY|phy.*(init|power).*(failed|error)|-EPROBE_DEFER' &&
	! has 'scsi host[0-9]+: ufshcd'; then
	echo "  UFS CONTROLLER FOUND, LINK DID NOT COME UP (phy/regulator/clock)"
	echo "  NEXT: look at the ufs lines above for -EPROBE_DEFER or a supply that"
	echo "        never appeared. On this board vcc is vreg_l12b and vccq2 is"
	echo "        vreg_l4f; a missing rail shows up as a deferral loop, not an"
	echo "        error. Run: cat /sys/kernel/debug/regulator/regulator_summary"
	exit 11
fi

if ! has 'scsi host[0-9]+: ufshcd|\[sda\]'; then
	echo "  UFS PROBED BUT NO SCSI DISK APPEARED"
	echo "  NEXT: the link started and then stalled. Look for timeouts above, and"
	echo "        check the DTB phy node is enabled too (&ufs_mem_phy), not just"
	echo "        the host controller."
	exit 12
fi

if [ -z "$parts" ]; then
	echo "  DISK IS THERE, NO PARTITIONS: GPT NOT PARSED OR TABLE MISSING"
	echo "  NEXT: cat /proc/partitions and blkid. If /dev/sda has no children,"
	echo "        either CONFIG_EFI_PARTITION is off (it defaults to y) or the"
	echo "        disk really has no GPT. ufs-layout.sh reports both."
	exit 13
fi

if ! blkid 2>/dev/null | grep -q 'LABEL="pmOS_root"'; then
	echo "  DISK AND PARTITIONS FINE, NO pmOS_root LABEL: ROOTFS LOOKUP FAILED"
	echo "  NEXT: this is the initramfs side, not UFS. Either the rootfs was"
	echo "        formatted without -L pmOS_root, or it lives in the super"
	echo "        partition and make-dynpart-mappings did not run (check"
	echo "        deviceinfo_super_partitions). Verify with: blkid /dev/sda*"
	exit 14
fi

if has 'unable to mount root partition|Detected unsupported'; then
	echo "  ROOTFS FOUND, MOUNT FAILED"
	echo "  NEXT: filesystem drove the wrong way. ext4 is built in; f2fs is a"
	echo "        module and must be in the initramfs or the mount cannot work."
	exit 15
fi

echo "  ROOTFS FOUND AND MOUNTED"
echo "  NEXT: if switch-root still did not happen, the failure is after mount:"
echo "        look for 'Switching root' and then the init binary in the rootfs."
exit 0
