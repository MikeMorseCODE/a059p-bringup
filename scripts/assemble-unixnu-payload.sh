#!/bin/sh
# Assemble a UniXNU payload FAT volume holding a Linux entry.
#
#     sh assemble-unixnu-payload.sh \
#         --kernel linux.efi \
#         --dtb milos-nothing-asteroids.dtb \
#         --initramfs initramfs-postmarketos \
#         --cmdline cmdline.txt \
#         --out payload.img
#
# UniXNU looks for EFI/UniXNU/unixnu.toml on the volume and boots the entries
# it lists, so the volume is built around that file rather than around a fixed
# set of names. Paths inside the TOML are relative to the volume root.
#
#   --dtb firmware   keeps the firmware FDT (Mu-Silicium's) instead of shipping
#                    a second DTB; pass a path to override it with your own.
#
# Needs mkfs.fat (dosfstools) and mcopy (mtools). This does not wrap the result
# in an Android boot image; that is `unixnu bootimg --uefi ... --dtb ...`.
#
# The initramfs is checked for the boot-failure dump and a warning is printed
# if it is absent, since a payload without it fails blind on this phone.

set -eu

KERNEL=""
DTB="Payloads/board.dtb"
DTBFILE=""
INITRAMFS=""
ARGS=""
CMDLINE=""
OUT=""
SIZE_MB=64

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
	case "$1" in
	--kernel) KERNEL=$2; shift 2 ;;
	--dtb) DTB=$2; shift 2 ;;
	--initramfs) INITRAMFS=$2; shift 2 ;;
	--args) ARGS=$2; shift 2 ;;
	--cmdline) CMDLINE=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--size-mb) SIZE_MB=$2; shift 2 ;;
	-h | --help) usage ;;
	*) echo "unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "$KERNEL" ] && [ -n "$INITRAMFS" ] && [ -n "$OUT" ] || usage
[ -r "$KERNEL" ] || { echo "cannot read $KERNEL" >&2; exit 1; }
[ -r "$INITRAMFS" ] || { echo "cannot read $INITRAMFS" >&2; exit 1; }

# --dtb firmware means "use the FDT the firmware passes in".
if [ "$DTB" != "firmware" ]; then
	[ -r "$DTB" ] || { echo "cannot read DTB $DTB" >&2; exit 1; }
	DTBFILE=$DTB
fi

if [ -n "$CMDLINE" ]; then
	[ -r "$CMDLINE" ] || { echo "cannot read $CMDLINE" >&2; exit 1; }
	ARGS=$(tr '\n' ' ' <"$CMDLINE" | sed 's/  */ /g; s/ $//')
fi

command -v mkfs.fat >/dev/null || { echo "mkfs.fat missing (dosfstools)" >&2; exit 1; }
command -v mcopy >/dev/null || { echo "mcopy missing (mtools)" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tree/EFI/UniXNU" "$work/tree/Payloads"

# Flag an initramfs without the failure dump. The marker is plain text inside
# the cpio payload, so no extraction is needed: decompress and grep the stream.
case "$(od -An -tx1 -N2 "$INITRAMFS" | tr -d ' \n')" in
1f8b) gzip -dc "$INITRAMFS" >"$work/irfs.raw" 2>/dev/null || cp "$INITRAMFS" "$work/irfs.raw" ;;
*) cp "$INITRAMFS" "$work/irfs.raw" ;;
esac
if ! grep -qa 'pmos_asteroids_boot_dump' "$work/irfs.raw" 2>/dev/null; then
	printf '%s\n' \
		'assemble-unixnu-payload: WARNING: initramfs has no boot failure dump.' \
		'  A failed boot will show only the splash error, with nothing on the' \
		'  framebuffer to photograph. Rebuild it with build-initramfs.sh, which' \
		'  injects the dump, or run scripts/inject-boot-dump.sh manually.' >&2
fi

cp "$KERNEL" "$work/tree/Payloads/linux.efi"
cp "$INITRAMFS" "$work/tree/Payloads/initramfs"
if [ -n "$DTBFILE" ]; then
	cp "$DTBFILE" "$work/tree/Payloads/board.dtb"
fi

if [ "$DTB" = "firmware" ]; then
	DTB_LINE='dtb = "firmware"'
else
	DTB_LINE='dtb = "Payloads/board.dtb"'
fi

cat >"$work/tree/EFI/UniXNU/unixnu.toml" <<EOF
version = 1

[boot]
timeout = 5
default = "linux"

[ui]
title = "Nothing Phone (3a) Pro"
layout = "auto"
console = "auto"

[[entry]]
id = "linux"
title = "postmarketOS"
type = "linux"
path = "Payloads/linux.efi"
$DTB_LINE
initrd = "Payloads/initramfs"
args = "$ARGS"
EOF

truncate -s "${SIZE_MB}M" "$work/payload.img"
mkfs.fat -F 16 -n UNIXNU "$work/payload.img" >/dev/null

# mcopy -s copies the directory tree; -i names the image
(cd "$work/tree" && mcopy -s -i "$work/payload.img" EFI Payloads ::/)

cp "$work/payload.img" "$OUT"

echo "wrote $OUT (${SIZE_MB} MiB FAT16)"
echo "kernel : Payloads/linux.efi"
[ -n "$DTBFILE" ] && echo "dtb    : Payloads/board.dtb"
[ "$DTB" = "firmware" ] && echo "dtb    : firmware (from the UEFI FDT)"
echo "initrd : Payloads/initramfs"
echo "args   : $ARGS"
mdir -/ -i "$OUT" ::/
