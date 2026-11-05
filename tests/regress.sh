#!/bin/sh
# Regression harness for the initramfs / payload toolchain.
#
#   sh tests/regress.sh              # compare against tests/expected/
#   sh tests/regress.sh --update     # rewrite the golden files
#
# Runs the whole pipeline with stubs (fake mkinitfs, fake dmesg/blkid, a fake
# framebuffer target) and compares the stable parts of the output with goldens.
# Anything that changes a message, an ordering, a count or a verdict fails.
#
# Needs: python3 (cpio-tool.py), gzip. For the payload steps also mkfs.fat and
# mcopy (dosfstools + mtools); those steps are skipped, visibly, without them.
#
# Exit: 0 all compared checks pass, 1 drift or assertion failure.

set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
S=$HERE/../scripts
FIX=$HERE/fixtures
EXP=$HERE/expected
FRAGMENT=$HERE/../initramfs/asteroids-boot-dump.sh

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/logs" "$work/stub" "$work/out" "$EXP"

passed=0
failed=0
skipped=0

ok() { printf '  [ok]   %s\n' "$*"; passed=$((passed + 1)); }
bad() { printf '  [FAIL] %s\n' "$*"; failed=$((failed + 1)); }
skip() { printf '  [skip] %s\n' "$*"; skipped=$((skipped + 1)); }

# Strip everything that legitimately differs between machines and runs.
norm() {
	sed -E \
		-e 's#/tmp/[A-Za-z0-9._/-]+#<tmp>#g' \
		-e 's/[0-9]+ bytes/<bytes>/g' \
		-e 's/^uptime: .*/uptime: <uptime>/'
}

golden_norm() { # <name> <raw-file>
	norm <"$2" >"$work/norm.tmp"
	golden "$1" "$work/norm.tmp"
}

golden() { # <name> <actual-file>
	if [ "$UPDATE" = 1 ]; then
		if cp "$2" "$EXP/$1"; then
			printf '  [update] %s\n' "$1"
		else
			bad "could not write golden $1"
		fi
		return
	fi
	if [ ! -f "$EXP/$1" ]; then
		bad "golden $1 missing (run --update)"
		return
	fi
	if diff -u "$EXP/$1" "$2" >"$work/diff" 2>&1; then
		ok "$1"
	else
		bad "drift in $1"
		sed -n '1,25p' "$work/diff" | sed 's/^/         /'
	fi
}

echo "== fixtures =="
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
chmod +x "$FIX/pmos/init" "$FIX/pmos/init_2nd.sh" "$FIX/pmos/bin/busybox" "$FIX/pmos/sbin/blkid"
python3 "$S/cpio-tool.py" create "$FIX/pmos" "$work/initramfs-pmos.gz" 2>/dev/null
python3 "$S/cpio-tool.py" create "$FIX/busybox" "$work/initramfs-busybox.gz" 2>/dev/null
ok "fixture initramfs archives built"

cat >"$work/stub/mkinitfs" <<'EOF'
#!/bin/sh
case "$1" in
--help) echo "usage: mkinitfs [-o OUTPUT]"; exit 0 ;;
-o) cp "$FIXTURE_INITRAMFS" "$2"; exit 0 ;;
*) exit 1 ;;
esac
EOF
chmod +x "$work/stub/mkinitfs"

echo
echo "== build + inject =="
FIXTURE_INITRAMFS=$work/initramfs-pmos.gz \
	PATH="$work/stub:$PATH" \
	sh "$S/build-initramfs.sh" --out "$work/out/initramfs-postmarketos.gz" \
	>"$work/build.raw" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "build exits 0" || bad "build exits $rc"
grep -E '^(== |  \[ok\]|  \[FAIL\]|RESULT)' "$work/build.raw" | norm >"$work/build.txt"
golden build.txt "$work/build.txt"

out=$work/out/initramfs-postmarketos.gz
[ "$(od -An -tx1 -N2 "$out" | tr -d ' \n')" = "1f8b" ] && ok "output is gzip" || bad "output is not gzip"
markers=$(gzip -dc "$out" | grep -ca 'pmos_asteroids_boot_dump')
[ "$markers" -eq 2 ] && ok "dump markers = 2" || bad "dump markers = $markers (expected 2)"
if python3 "$S/cpio-tool.py" list "$out" >/dev/null 2>&1; then
	ok "archive lists cleanly"
else
	bad "archive does not list"
fi

echo
echo "== injection is idempotent =="
sh "$S/inject-boot-dump.sh" "$out" -o "$work/out/second.gz" >"$work/inject.raw" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "re-injection exits 0" || bad "re-injection exits $rc"
grep -E 'already injected|injected boot dump|fail_halt_boot definitions' "$work/inject.raw" |
	norm >"$work/inject.txt"
golden inject.txt "$work/inject.txt"
if cmp -s "$out" "$work/out/second.gz"; then
	ok "re-injection is byte-identical"
else
	bad "re-injection changed the archive"
fi

echo
echo "== payload assembly =="
printf 'console=tty0 console=ttyMSM0,115200n8 pmos.debug-shell\n' >"$work/cmdline.txt"
printf 'Nothing Phone (3a) Pro\n' >"$work/model"
mkdir -p "$work/nodev"
python3 - "$work" <<'PY'
import struct, sys, pathlib
w = pathlib.Path(sys.argv[1])
hdr = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8
hdr += struct.pack("<HHI", 2, 183, 1)
hdr += struct.pack("<QQQ", 0, 0, 0)
hdr += struct.pack("<IHHHHHH", 0, 0, 0, 0, 0, 0, 0)
(w / "Image").write_bytes(hdr + b"\0" * 512)
(w / "board.dtb").write_bytes(bytes.fromhex("d00dfeed") + b"\0" * 256)
PY
ok "kernel and DTB stand-ins written"

have_mtools=1
for t in mkfs.fat mcopy mdir; do
	command -v "$t" >/dev/null || have_mtools=0
done

if [ "$have_mtools" = 1 ]; then
	sh "$S/assemble-unixnu-payload.sh" --kernel "$work/Image" --dtb "$work/board.dtb" \
		--initramfs "$out" --cmdline "$work/cmdline.txt" --out "$work/payload.img" \
		>"$work/asm-dumped.raw" 2>&1
	rc=$?
	[ "$rc" -eq 0 ] && ok "assemble (dumped) exits 0" || bad "assemble (dumped) exits $rc"
	if grep -q 'WARNING' "$work/asm-dumped.raw"; then
		bad "dumped initramfs still warns"
	else
		ok "dumped initramfs does not warn"
	fi
	sed '/^ Volume in drive/,$d' "$work/asm-dumped.raw" | norm >"$work/asm-dumped.txt"
	golden assemble-dumped.txt "$work/asm-dumped.txt"

	sh "$S/assemble-unixnu-payload.sh" --kernel "$work/Image" --dtb "$work/board.dtb" \
		--initramfs "$work/initramfs-pmos.gz" --cmdline "$work/cmdline.txt" \
		--out "$work/payload-undumped.img" >"$work/asm-undumped.raw" 2>&1
	rc=$?
	[ "$rc" -eq 0 ] && ok "assemble (undumped) still exits 0" || bad "assemble (undumped) exits $rc"
	grep -q 'WARNING: initramfs has no boot failure dump' "$work/asm-undumped.raw" &&
		ok "undumped initramfs warns" || bad "undumped initramfs did not warn"
	sed '/^ Volume in drive/,$d' "$work/asm-undumped.raw" | norm >"$work/asm-undumped.txt"
	golden assemble-undumped.txt "$work/asm-undumped.txt"

	echo
	echo "== payload checks =="
	sh "$S/check-payload.sh" "$work/payload.img" >"$work/chk-dumped.raw" 2>&1
	rc=$?
	[ "$rc" -eq 0 ] && ok "checker accepts the dumped payload" || bad "checker rejects the dumped payload ($rc)"
	grep -E '^(==|  \[|RESULT)' "$work/chk-dumped.raw" | norm >"$work/chk-dumped.txt"
	golden check-dumped.txt "$work/chk-dumped.txt"

	sh "$S/check-payload.sh" "$work/payload-undumped.img" >"$work/chk-undumped.raw" 2>&1
	rc=$?
	[ "$rc" -eq 0 ] && ok "checker accepts the undumped payload" || bad "checker rejects the undumped payload ($rc)"
	grep -q '\[info\] no boot failure dump' "$work/chk-undumped.raw" &&
		ok "checker reports the missing dump" || bad "checker stayed silent about the missing dump"
	grep -E '^(==|  \[|RESULT)' "$work/chk-undumped.raw" | norm >"$work/chk-undumped.txt"
	golden check-undumped.txt "$work/chk-undumped.txt"

	mdir -/ -i "$work/payload.img" ::/ 2>/dev/null |
		grep -o '::/[^ ]*' | sort -u >"$work/files.txt"
	golden payload-files.txt "$work/files.txt"
else
	skip "payload assembly and checks (mkfs.fat/mcopy/mdir missing: install dosfstools mtools)"
fi

echo
echo "== failure dump =="
[ -f "$FRAGMENT" ] || { bad "fragment missing: $FRAGMENT"; exit 1; }

cat >"$work/stub/dmesg" <<'EOF'
#!/bin/sh
printf 'ufshcd-qcom 1d84000.ufshc: ufshcd_pltfrm_init() done\n'
printf 'scsi host0: ufshcd\n'
printf ' sd 0:0:0:0: [sda] 488397168 4096-byte logical blocks\n'
EOF
cat >"$work/stub/blkid-full" <<'EOF'
#!/bin/sh
printf '/dev/sda1: PARTLABEL="super" TYPE="none"\n'
printf '/dev/sda12: LABEL="pmOS_root" UUID="abcd" TYPE="ext4"\n'
EOF
cat >"$work/stub/blkid-partial" <<'EOF'
#!/bin/sh
printf '/dev/sda1: PARTLABEL="super" TYPE="none"\n'
EOF
cat >"$work/stub/dmesg-noufs" <<'EOF'
#!/bin/sh
printf '[    0.1] Linux version 7.3.0\n'
EOF
chmod +x "$work/stub/dmesg" "$work/stub/blkid-full" "$work/stub/blkid-partial" "$work/stub/dmesg-noufs"

printf 'major minor  #blocks  name\n\n   8        0  244198584 sda\n   8        1    2097152 sda1\n   8       12  240000000 sda12\n' >"$work/parts-full"
printf 'major minor  #blocks  name\n\n   8        0  244198584 sda\n' >"$work/parts-disk"

run_dump() { # <dmesg> <blkid> <parts> <out>
	PATH="$work/stub:$PATH" PMOS_DUMP_TTY="$4" PMOS_DUMP_PARTITIONS="$3" \
		PMOS_DUMP_CMDLINE="$work/cmdline.txt" PMOS_DUMP_MODEL_FILE="$work/model" \
		PMOS_DUMP_PARTLABEL_DIR="$work/nodev" PMOS_DUMP_MAPPER_DIR="$work/nodev" \
		sh -c "dmesg() { sh '$1'; }; blkid() { sh '$2'; }; . '$FRAGMENT'; pmos_asteroids_boot_dump" 2>&1
}

run_dump "$work/stub/dmesg" "$work/stub/blkid-full" "$work/parts-full" "$work/dump-1.txt"
golden_norm dump-1.txt "$work/dump-1.txt"

run_dump "$work/stub/dmesg" "$work/stub/blkid-partial" "$work/parts-full" "$work/dump-2.txt"
run_dump "$work/stub/dmesg-noufs" "$work/stub/blkid-partial" "$work/parts-full" "$work/dump-3.txt"
run_dump "$work/stub/dmesg" "$work/stub/blkid-partial" "$work/parts-disk" "$work/dump-4.txt"

{ for i in 1 2 3 4; do
	grep ' VERDICT' "$work/dump-$i.txt"
done; } >"$work/verdicts.txt"
golden verdicts.txt "$work/verdicts.txt"

echo
echo "== classifier =="
{ for t in a b c d; do
	case $t in
	a) d=$work/stub/dmesg-noufs; p=$work/parts-full ;;
	b) printf 'ufshcd-qcom 1d84000.ufshc: ufshcd_pltfrm_init() failed: -517\nqmp-ufs-phy 1d80000.phy: phy init failed, ret=-517\n' >"$work/log-b"; d=$work/log-b; p=$work/parts-disk ;;
	c) printf 'ufshcd-qcom 1d84000.ufshc: ufshcd_pltfrm_init() done\n' >"$work/log-c"; d=$work/log-c; p=$work/parts-disk ;;
	d) sh "$work/stub/dmesg" >"$work/log-d"; d=$work/log-d; p=$work/parts-full ;;
	esac
	sh "$S/diagnose-boot.sh" --dmesg "$d" --partitions "$p" >"$work/dg-$t.txt" 2>&1
	echo "rc=$? verdict=$(sed -n '/== verdict ==/,$p' "$work/dg-$t.txt" | sed -n '2p' | sed 's/^ *//')"
done; } >"$work/diagnose.txt"
golden diagnose.txt "$work/diagnose.txt"

echo
echo "== failure modes =="
mkdir -p "$work/lonely"
cp "$S/build-initramfs.sh" "$work/lonely/"
FIXTURE_INITRAMFS=$work/initramfs-pmos.gz PATH="$work/stub:$PATH" \
	sh "$work/lonely/build-initramfs.sh" --out "$work/out/x.gz" >"$work/lonely.raw" 2>&1
rc=$?
[ "$rc" -eq 1 ] && ok "missing injector fails the build" || bad "missing injector exit code was $rc"
grep -q 'inject-boot-dump.sh is not next to this script' "$work/lonely.raw" &&
	ok "missing injector message" || bad "missing injector message changed"

echo
printf '%s\n' "RESULT: $passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ] || exit 1
exit 0
