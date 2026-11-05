#!/bin/sh
# Verify the aport that `make apk` generates, and optionally build the .apk.
#
#   sh ci/apk.sh            integrity only: template, version, checksum, tarball
#   sh ci/apk.sh --abuild   also build with abuild and install the result
#
# The integrity half needs make, tar, sha512sum, sed, diff and grep, so it runs
# on any Linux host. --abuild needs abuild and apk-tools (apk add alpine-sdk)
# and must not run as root: abuild refuses to.
#
# Everything below fails loudly. There are no soft skips on purpose: a check
# that cannot run is a failed job, not a green one.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

with_abuild=no
case ${1:-} in
--abuild) with_abuild=yes ;;
"") ;;
*) echo "usage: sh ci/apk.sh [--abuild]" >&2; exit 2 ;;
esac
if [ $# -gt 1 ]; then
	echo "usage: sh ci/apk.sh [--abuild]" >&2
	exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

n=0
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
ok() {
	n=$((n + 1))
	echo "ok $n - $*"
}

# --- what this tree is -------------------------------------------------------
[ -f VERSION ] || fail "no VERSION file"
version=$(cat VERSION)
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
	fail "VERSION '$version' is not x.y.z"
pkgname=$(sed -n 's/^PKGNAME[[:space:]]*:*=[[:space:]]*//p' Makefile | head -1 | cut -d' ' -f1)
[ -n "$pkgname" ] || fail "cannot read PKGNAME from the Makefile"
ok "VERSION $version, package $pkgname"

# --- generate the aport as a user would --------------------------------------
rm -rf dist/apk
make apk >"$work/make.log" 2>&1 || {
	cat "$work/make.log" >&2
	fail "make apk failed"
}
aport=dist/apk/APKBUILD
tarball="dist/apk/$pkgname-$version.tar.gz"
[ -f "$aport" ] || fail "make apk did not write $aport"
[ -f "$tarball" ] || fail "make apk did not write $tarball"
ok "make apk wrote $aport and $tarball"

sh -n "$aport" || fail "$aport is not valid shell"
ok "APKBUILD parses as shell"

# --- the aport must describe this tree, not a previous one -------------------
grep -qx "pkgver=$version" "$aport" ||
	fail "APKBUILD pkgver does not match VERSION ($version)"
grep -qx "pkgname=$pkgname" "$aport" ||
	fail "APKBUILD pkgname does not match PKGNAME ($pkgname)"
ok "pkgname and pkgver match the tree"

# A surviving @NAME@ means the template grew a field the Makefile does not fill
# in; abuild would then package the literal placeholder text.
if grep -Eq '@[A-Z0-9_]+@' "$aport"; then
	grep -E '@[A-Z0-9_]+@' "$aport" >&2
	fail "unsubstituted placeholder left in the APKBUILD"
fi
ok "no unsubstituted placeholders"

# --- sha512sums must match the tarball as it exists now ----------------------
sed -n '/^sha512sums="/,/^"/p' "$aport" | sed '1d;$d' >"$work/sums"
[ -s "$work/sums" ] || fail "APKBUILD has empty sha512sums"
grep -q "  $pkgname-$version.tar.gz$" "$work/sums" ||
	fail "sha512sums does not cover $pkgname-$version.tar.gz"
(cd dist/apk && sha512sum -c "$work/sums") ||
	fail "sha512sums does not match the tarball"
ok "sha512sums matches the tarball"

# --- generated APKBUILD must equal the template rendered for this tree -------
sum=$(sha512sum "$tarball" | cut -d' ' -f1)
sed -e "s/@PKGVER@/$version/" -e "s/@SHA512@/$sum/" \
	-e "s/@TARBALL@/$pkgname-$version.tar.gz/" packaging/APKBUILD.in >"$work/APKBUILD"
if ! diff -u "$work/APKBUILD" "$aport"; then
	fail "generated APKBUILD drifted from packaging/APKBUILD.in"
fi
ok "APKBUILD is the template rendered for this tree, nothing else"

# --- tarball shape ----------------------------------------------------------
tar -tzf "$tarball" >"$work/list" || fail "cannot list $tarball"
[ -s "$work/list" ] || fail "$tarball is empty"
tops=$(cut -d/ -f1 "$work/list" | sort -u | tr '\n' ' ')
[ "$tops" = "$pkgname-$version " ] ||
	fail "tarball top level is '$tops', expected '$pkgname-$version'"
ok "tarball has one top-level directory, $pkgname-$version"

# Build products and VCS metadata must never reach the package source.
for bad in /dist/ /__pycache__/ /.git/ /.github/; do
	if grep -qF "$bad" "$work/list"; then
		grep -F "$bad" "$work/list" >&2
		fail "tarball contains $bad"
	fi
done
ok "tarball carries no dist/, __pycache__, .git or .github"

for f in Makefile VERSION README.md packaging/APKBUILD.in \
	initramfs/asteroids-boot-dump.sh tests/regress.sh scripts/cpio-tool.py; do
	grep -qx "$pkgname-$version/$f" "$work/list" || fail "tarball is missing $f"
done
tar -xzOf "$tarball" "$pkgname-$version/VERSION" >"$work/VERSION.in" ||
	fail "cannot read VERSION out of the tarball"
[ "$(cat "$work/VERSION.in")" = "$version" ] ||
	fail "VERSION inside the tarball is not $version"
ok "tarball carries the build inputs and the same VERSION"

# --- optionally: build it for real ------------------------------------------
if [ "$with_abuild" = yes ]; then
	command -v abuild >/dev/null 2>&1 ||
		fail "--abuild needs abuild, apk and apk-tools (apk add alpine-sdk)"
	: "${PACKAGER:=CI <ci@example.invalid>}"
	export PACKAGER

	aportdir=$work/aport/$pkgname
	mkdir -p "$aportdir" "$work/src" "$work/pkgs"
	cp "$aport" "$aportdir/APKBUILD"
	# For a local source=tar.gz, abuild reads from the APKBUILD directory
	# (startdir), not SRCDEST; keep a copy beside the APKBUILD.
	cp "$tarball" "$aportdir/"
	cp "$tarball" "$work/src/"

	[ -f "$HOME/.abuild/abuild.conf" ] || abuild-keygen -a -n -q >/dev/null 2>&1 ||
		fail "abuild-keygen failed"

	(cd "$aportdir" && abuild -r -s "$work/src" -P "$work/pkgs") >"$work/abuild.log" 2>&1 || {
		tail -n 40 "$work/abuild.log" >&2
		fail "abuild failed (it runs check() and package() from the APKBUILD)"
	}
	apkfile=$(find "$work/pkgs" -type f -name "$pkgname-$version-r*.apk" | head -1)
	[ -n "$apkfile" ] || fail "abuild reported success but produced no .apk"
	ok "abuild built $(basename "$apkfile")"

	# Install it into an empty root: this is the closest thing to a real
	# userland install that needs no network and no pmOS rootfs.
	installroot=$work/rootfs
	mkdir -p "$installroot"
	apk add --root "$installroot" --initdb --no-depends --allow-untrusted "$apkfile" \
		>"$work/apkadd.log" 2>&1 || {
		cat "$work/apkadd.log" >&2
		fail "apk add of the built package failed"
	}
	for t in check-payload assemble-unixnu-payload build-initramfs inject-boot-dump \
		diagnose-boot ufs-layout rootfs-plan; do
		[ -x "$installroot/usr/bin/asteroids-$t" ] ||
			fail ".apk is missing /usr/bin/asteroids-$t"
	done
	[ -f "$installroot/usr/share/asteroids-port/initramfs/asteroids-boot-dump.sh" ] ||
		fail ".apk is missing the initramfs fragment"
	ok ".apk installs all seven tools and the share tree"

	set +e
	"$installroot/usr/bin/asteroids-check-payload" >"$work/wrapper.log" 2>&1
	rc=$?
	set -e
	[ "$rc" = 2 ] || {
		cat "$work/wrapper.log" >&2
		fail "installed wrapper exited $rc, expected 2 (usage)"
	}
	ok "a wrapper installed from the .apk runs and finds its share tree"

	# Packaging must not quietly change the layout people get from make install.
	make -s install DESTDIR="$work/install" PREFIX=/usr >/dev/null ||
		fail "make install failed"
	(cd "$installroot" && find . -type f | sort) >"$work/apk.files"
	(cd "$work/install" && find . -type f | sort) >"$work/install.files"
	if ! diff -u "$work/install.files" "$work/apk.files"; then
		fail ".apk file list differs from make install"
	fi
	ok ".apk layout is identical to make install ($(wc -l <"$work/apk.files") files)"
fi

echo "ALL CHECKS PASSED ($n)"
