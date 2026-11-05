#!/bin/sh
# Inspect a UniXNU payload volume and say whether it can reach switch-root.
#
#     sh check-payload.sh payload.img
#
# Reads EFI/UniXNU/unixnu.toml, follows the Linux entry's kernel/initrd paths,
# and checks the initramfs really contains postmarketOS' init. A plain BusyBox
# initramfs boots to a shell and never calls mount_root_partition(), so it can
# never switch root - that is the failure this catches before you flash.

set -u

IMG=${1:-}
[ -n "$IMG" ] && [ -r "$IMG" ] || { echo "usage: $0 <payload.img>" >&2; exit 2; }
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

for t in mdir mtype mcopy; do
	command -v "$t" >/dev/null || { echo "$t missing (mtools)" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
ok() { printf '  [ok]   %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; fail=1; }
note() { printf '  [info] %s\n' "$*"; }

echo "== volume =="
mdir -i "$IMG" ::/ || { echo "not a FAT image" >&2; exit 1; }

echo
echo "== unixnu.toml =="
if ! mtype -i "$IMG" ::/EFI/UniXNU/unixnu.toml >"$work/unixnu.toml" 2>/dev/null; then
	bad "EFI/UniXNU/unixnu.toml missing: UniXNU will ignore this volume"
	ENTRY=""
else
	ok "EFI/UniXNU/unixnu.toml present"
	ENTRY=$(python3 - "$work/unixnu.toml" <<'PY'
import sys
try:
    import tomllib
    data = tomllib.load(open(sys.argv[1], "rb"))
except Exception as exc:
    print("PARSE_ERROR\t%s" % exc)
    raise SystemExit(0)
for entry in data.get("entry", []):
    if entry.get("type") == "linux":
        print("\t".join([
            entry.get("path", ""),
            entry.get("dtb", ""),
            entry.get("initrd", ""),
            entry.get("args", ""),
        ]))
        break
PY
)
	if [ -z "$ENTRY" ]; then
		bad "no [[entry]] with type = \"linux\""
	elif [ "${ENTRY%%	*}" = "PARSE_ERROR" ]; then
		bad "unixnu.toml does not parse: ${ENTRY#*	}"
		ENTRY=""
	else
		ok "linux entry found"
	fi
fi

KPATH=$(printf '%s' "$ENTRY" | cut -f1)
DPROP=$(printf '%s' "$ENTRY" | cut -f2)
IPATH=$(printf '%s' "$ENTRY" | cut -f3)
ARGS=$(printf '%s' "$ENTRY" | cut -f4)
[ -n "$KPATH" ] && note "kernel : $KPATH"
[ -n "$IPATH" ] && note "initrd : $IPATH"
[ -n "$ARGS" ] && note "args   : $ARGS"
[ -n "$DPROP" ] && note "dtb    : $DPROP"

echo
echo "== kernel =="
if [ -z "$KPATH" ] || ! mcopy -n -i "$IMG" "::$KPATH" "$work/k" 2>/dev/null; then
	bad "kernel not readable at ${KPATH:-<unset>}"
else
	magic=$(od -An -tx1 -N4 "$work/k" | tr -d ' \n')
	case "$magic" in
	7f454c46)
		ok "ELF"
		readelf -h "$work/k" 2>/dev/null | grep -q 'AArch64' && ok "aarch64" || bad "not aarch64"
		file "$work/k" 2>/dev/null | grep -qi 'EFI' && ok "EFI application" ||
			note "no EFI metadata visible; confirm CONFIG_EFI_STUB=y"
		;;
	64486b37) ok "raw aarch64 Image" ;;
	1f8b) ok "gzip-compressed kernel" ;;
	*) bad "kernel magic $magic is not ELF/Image/gzip" ;;
	esac
fi

echo
echo "== dtb =="
case "$DPROP" in
firmware) note "entry uses the firmware FDT; nothing to check here" ;;
"") note "no dtb key: UniXNU passes the firmware FDT" ;;
*)
	if mcopy -n -i "$IMG" "::$DPROP" "$work/d" 2>/dev/null; then
		magic=$(od -An -tx1 -N4 "$work/d" | tr -d ' \n')
		[ "$magic" = "d00dfeed" ] && ok "$DPROP has FDT magic" ||
			bad "$DPROP magic $magic is not 0xd00dfeed"
		note "$DPROP is $(stat -c %s "$work/d") bytes"
	else
		bad "dtb not readable at $DPROP"
	fi
	;;
esac

echo
echo "== initramfs =="
if [ -z "$IPATH" ] || ! mcopy -n -i "$IMG" "::$IPATH" "$work/i" 2>/dev/null; then
	bad "initramfs not readable at ${IPATH:-<unset>}"
else
	note "$IPATH is $(stat -c %s "$work/i") bytes"
	mkdir -p "$work/root"
	python3 "$HERE/cpio-tool.py" extract "$work/i" "$work/root" 2>/dev/null ||
		bad "initramfs is not a newc cpio archive"

	if [ -f "$work/root/init" ] && grep -q 'PMOS STAGE 1' "$work/root/init" 2>/dev/null; then
		ok "init is postmarketOS init.sh"
	elif [ -f "$work/root/init" ]; then
		bad "init is not pmOS init.sh (BusyBox-style image: never reaches switch-root)"
	else
		bad "no /init in the initramfs"
	fi

	[ -f "$work/root/init_functions.sh" ] && ok "init_functions.sh" || bad "init_functions.sh missing"
	if grep -q 'pmos_asteroids_boot_dump' "$work/root/init_functions.sh" 2>/dev/null; then
		ok "boot failure dump injected (partitions, blkid, ufs -> framebuffer)"
	else
		note "no boot failure dump: a failed boot shows only the splash error"
	fi
	[ -f "$work/root/init_2nd.sh" ] && ok "init_2nd.sh" || bad "init_2nd.sh missing"
	[ -f "$work/root/usr/share/misc/source_deviceinfo" ] && ok "source_deviceinfo" ||
		bad "source_deviceinfo missing: deviceinfo would be empty"

	found_busybox=0
	for p in bin/busybox usr/bin/busybox sbin/busybox; do
		[ -e "$work/root/$p" ] && found_busybox=1
	done
	[ "$found_busybox" = 1 ] && ok "busybox" || bad "busybox missing (init.sh needs it)"

	found_blkid=0
	for p in sbin/blkid usr/sbin/blkid bin/blkid usr/bin/blkid; do
		[ -e "$work/root/$p" ] && found_blkid=1
	done
	[ "$found_blkid" = 1 ] && ok "blkid (rootfs label lookup)" ||
		bad "blkid missing: find_root_partition cannot find pmOS_root"

	if grep -q 'make-dynpart-mappings' "$work/root/init_functions.sh" 2>/dev/null; then
		found_dyn=0
		for p in usr/bin/make-dynpart-mappings usr/sbin/make-dynpart-mappings; do
			[ -e "$work/root/$p" ] && found_dyn=1
		done
		[ "$found_dyn" = 1 ] && ok "make-dynpart-mappings (layout B possible)" ||
			note "initramfs references make-dynpart-mappings but lacks it: layout A only"
	fi

	[ -d "$work/root/lib/modules" ] && note "modules: $(ls "$work/root/lib/modules" 2>/dev/null | head -1)"
fi

echo
echo "== boot args =="
if [ -n "${ARGS:-}" ]; then
	printf '%s' "$ARGS" | grep -q 'pmos.debug-shell' && note "debug shell enabled" ||
		note "no pmos.debug-shell: add it for the first boot"
	printf '%s' "$ARGS" | grep -q 'console=' && ok "a console= is set" ||
		bad "no console= in args: you get no output"
else
	bad "entry has no args: no console, no debug shell"
fi

echo
if [ "$fail" -ne 0 ]; then
	echo "RESULT: this payload will not reach switch-root (see FAIL lines)"
	exit 1
fi
echo "RESULT: payload is coherent; switch-root then depends on the rootfs being found"
