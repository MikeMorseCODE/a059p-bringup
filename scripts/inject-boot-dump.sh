#!/bin/sh
# Inject the boot-failure dump into a built postmarketOS initramfs.
#
#     sh inject-boot-dump.sh initramfs-postmarketos -o initramfs-dumped
#
# The dump is appended to /init_functions.sh inside the archive, which redefines
# fail_halt_boot() so every failure path in wait_partition / mount_root_partition
# prints the partition table, blkid, by-partlabel, mapper state and the UFS
# kernel lines to the framebuffer before it halts.
#
# Appending works because init.sh and init_2nd.sh source the whole file before
# any of those functions run, so the later definition wins. Idempotent: running
# it twice does not add a second copy.
#
# Needs python3 (uses cpio-tool.py next to this script; no cpio binary needed).

set -eu

IN=""
OUT=""
DUMP=""

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
	case "$1" in
	-o | --out) OUT=$2; shift 2 ;;
	--fragment) DUMP=$2; shift 2 ;;
	-h | --help) usage ;;
	-*) echo "unknown argument: $1" >&2; usage ;;
	*) IN=$1; shift ;;
	esac
done

[ -n "$IN" ] || usage
[ -r "$IN" ] || { echo "cannot read $IN" >&2; exit 1; }

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
[ -n "$DUMP" ] || DUMP=$HERE/../initramfs/asteroids-boot-dump.sh
[ -r "$DUMP" ] || { echo "cannot read fragment $DUMP" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

# Preserve the input's compression in the default output name.
if [ -z "$OUT" ]; then
	case "$IN" in
	*.gz) OUT=${IN%.gz}-dumped.gz ;;
	*) OUT=$IN-dumped ;;
	esac
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root"

python3 "$HERE/cpio-tool.py" extract "$IN" "$work/root" 2>/dev/null ||
	{ echo "$IN is not a readable newc cpio archive" >&2; exit 1; }

IFS=$(printf '\n')
[ -f "$work/root/init_functions.sh" ] ||
	{ echo "no /init_functions.sh in the archive: not a pmOS initramfs" >&2; exit 1; }
grep -q 'pmos_asteroids_boot_dump' "$work/root/init_functions.sh" && {
	echo "already injected, nothing to do"
	cp "$IN" "$OUT"
	exit 0
}

[ -n "$(tail -c1 "$work/root/init_functions.sh")" ] && echo "" >>"$work/root/init_functions.sh"
cat "$DUMP" >>"$work/root/init_functions.sh"

python3 "$HERE/cpio-tool.py" create "$work/root" "$work/out.cpio" 2>/dev/null
case "$OUT" in
*.gz) gzip -n -9 -c "$work/out.cpio" >"$OUT" ;;
*) cp "$work/out.cpio" "$OUT" ;;
esac

echo "injected boot dump into $OUT ($(stat -c %s "$OUT") bytes)"
echo "  fail_halt_boot definitions: $(grep -c '^fail_halt_boot()' "$work/root/init_functions.sh") (2 = override in place)"
