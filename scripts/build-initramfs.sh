#!/bin/sh
# Produce the postmarketOS initramfs for this device, offline, and check it.
#
# This does not reimplement mkinitfs: it drives the real one inside a pmOS
# rootfs, injects the boot-failure dump, then verifies the archive has what
# switch-root and the failure path both need.
#
# Preferred, inside a pmbootstrap chroot (aarch64 rootfs, runs the real tools):
#   pmbootstrap init      # device: nothing-asteroids, then exit
#   pmbootstrap install --no-sshd        # populates the chroot
#   pmbootstrap chroot -r -- sh /tmp/build-initramfs.sh --out /tmp/initramfs
#   pmbootstrap export                   # copies results to /tmp/postmarketOS-export
#
# Or on a host with a pmOS rootfs unpacked at /mnt/pmos (needs root for chroot):
#   sudo sh build-initramfs.sh --rootfs /mnt/pmos --out ./initramfs-postmarketos
#
# The dump is not optional: a failed boot without it shows only the splash
# error, and on this phone serial is on test points.

set -eu

OUT=""
ROOTFS=""

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
	case "$1" in
	--out) OUT=$2; shift 2 ;;
	--rootfs) ROOTFS=$2; shift 2 ;;
	-h | --help) usage ;;
	*) echo "unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "$OUT" ] || usage
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Enter the rootfs when one was given and we are not already inside it.
if [ -n "$ROOTFS" ]; then
	[ -d "$ROOTFS" ] || { echo "no such rootfs: $ROOTFS" >&2; exit 1; }
	command -v chroot >/dev/null || { echo "chroot missing" >&2; exit 1; }
	# Copy the toolkit in with its directory layout intact, so the injection
	# step can find the fragment via ../initramfs/ inside the chroot too.
	mkdir -p "$ROOTFS/tmp/asteroids/scripts" "$ROOTFS/tmp/asteroids/initramfs"
	for f in build-initramfs.sh cpio-tool.py inject-boot-dump.sh; do
		cp "$HERE/$f" "$ROOTFS/tmp/asteroids/scripts/$f" || exit 1
	done
	if [ -f "$HERE/../initramfs/asteroids-boot-dump.sh" ]; then
		cp "$HERE/../initramfs/asteroids-boot-dump.sh" \
			"$ROOTFS/tmp/asteroids/initramfs/asteroids-boot-dump.sh" || exit 1
	else
		echo "missing initramfs/asteroids-boot-dump.sh" >&2
		exit 1
	fi
	chroot "$ROOTFS" /bin/sh /tmp/asteroids/scripts/build-initramfs.sh --out "$OUT"
	exit $?
fi

echo "== preflight =="
if [ -e /etc/os-release ]; then
	# shellcheck disable=SC1091
	. /etc/os-release 2>/dev/null || true
fi
echo "  rootfs: ${PRETTY_NAME:-unknown}"

MKINITFS=""
for cand in /sbin/mkinitfs /usr/sbin/mkinitfs /usr/bin/mkinitfs /bin/mkinitfs; do
	if [ -x "$cand" ]; then
		MKINITFS=$cand
		break
	fi
done
if [ -z "$MKINITFS" ]; then
	if command -v mkinitfs >/dev/null 2>&1; then
		MKINITFS=$(command -v mkinitfs)
	fi
fi
if [ -z "$MKINITFS" ]; then
	cat >&2 <<'EOF'
  [FAIL] mkinitfs not found: this is not a postmarketOS rootfs.
         Install the pieces first (inside the rootfs):
             apk add postmarketos-mkinitfs postmarketos-initramfs \
                     postmarketos-base device-nothing-asteroids
         then rerun this script.
EOF
	exit 1
fi
echo "  mkinitfs: $MKINITFS"

if [ ! -f /usr/share/misc/source_deviceinfo ]; then
	echo "  [warn] /usr/share/misc/source_deviceinfo missing (no device package installed)"
	echo "         the initramfs will boot with an empty deviceinfo"
fi

if [ -f /etc/mkinitfs/mkinitfs.conf ]; then
	echo "  config: /etc/mkinitfs/mkinitfs.conf"
	if grep -qE '^features=' /etc/mkinitfs/mkinitfs.conf; then
		echo "          $(grep -E '^features=' /etc/mkinitfs/mkinitfs.conf)"
	fi
else
	echo "  [warn] /etc/mkinitfs/mkinitfs.conf missing; mkinitfs defaults apply"
fi

echo
echo "== build =="
if "$MKINITFS" --help 2>&1 | grep -q -- '-o'; then
	"$MKINITFS" -o "$OUT"
else
	"$MKINITFS"
	for cand in /boot/initramfs-postmarketos /boot/initramfs; do
		if [ -f "$cand" ]; then
			cp "$cand" "$OUT"
			break
		fi
	done
fi
if [ ! -f "$OUT" ]; then
	echo "[FAIL] no initramfs produced at $OUT" >&2
	exit 1
fi
echo "  wrote $OUT ($(stat -c %s "$OUT") bytes)"

echo
echo "== inject the boot failure dump =="
if [ ! -f "$HERE/inject-boot-dump.sh" ]; then
	echo "  [FAIL] inject-boot-dump.sh is not next to this script" >&2
	echo "         copy the scripts/ and initramfs/ directories together" >&2
	exit 1
fi
tmp_out="$OUT.dump-tmp"
case "$OUT" in
*.gz) tmp_out="$OUT.dump-tmp.gz" ;;
esac
if ! sh "$HERE/inject-boot-dump.sh" "$OUT" -o "$tmp_out"; then
	rm -f "$tmp_out"
	echo "  [FAIL] could not inject the dump" >&2
	exit 1
fi
mv "$tmp_out" "$OUT"
echo "  [ok]   dump in place ($(stat -c %s "$OUT") bytes)"

echo
echo "== verify (what switch-root and the failure path need) =="
fail=0
py=""
for cand in python3 python; do
	if command -v "$cand" >/dev/null 2>&1; then
		py=$cand
		break
	fi
done

if [ -z "$py" ] || [ ! -f "$HERE/cpio-tool.py" ]; then
	echo "  [warn] python or cpio-tool.py unavailable; skipping archive checks"
	echo
	echo "RESULT: built and injected, but unverified"
	exit 0
fi

tmp=$(mktemp -d)
if ! $py "$HERE/cpio-tool.py" extract "$OUT" "$tmp" 2>/dev/null; then
	echo "  [FAIL] archive is not a readable cpio"
	rm -rf "$tmp"
	echo
	echo "RESULT: initramfs is unusable"
	exit 1
fi

if [ -f "$tmp/init" ] && grep -q 'PMOS STAGE 1' "$tmp/init" 2>/dev/null; then
	echo "  [ok]   init is pmOS init.sh"
else
	echo "  [FAIL] init is not pmOS init.sh"
	fail=1
fi
if [ -f "$tmp/init_functions.sh" ]; then
	echo "  [ok]   init_functions.sh"
else
	echo "  [FAIL] init_functions.sh"
	fail=1
fi
if [ -f "$tmp/usr/share/misc/source_deviceinfo" ]; then
	echo "  [ok]   source_deviceinfo"
else
	echo "  [FAIL] source_deviceinfo"
	fail=1
fi

found_blkid=0
for p in sbin/blkid usr/sbin/blkid bin/blkid usr/bin/blkid; do
	if [ -e "$tmp/$p" ]; then
		found_blkid=1
	fi
done
if [ "$found_blkid" = 1 ]; then
	echo "  [ok]   blkid"
else
	echo "  [FAIL] blkid (find_root_partition cannot look up pmOS_root)"
	fail=1
fi

if grep -q 'pmos_asteroids_boot_dump' "$tmp/init_functions.sh" 2>/dev/null; then
	echo "  [ok]   boot failure dump installed"
else
	echo "  [FAIL] boot failure dump missing after injection"
	fail=1
fi
rm -rf "$tmp"

echo
if [ "$fail" -ne 0 ]; then
	echo "RESULT: initramfs cannot reach switch-root"
	exit 1
fi
echo "RESULT: initramfs has the dump; next: assemble the UniXNU payload"
