# A059P bring-up toolkit

Tooling for running postmarketOS on the **Nothing Phone (3a) Pro** (`A059P`,
SM7635 "milos") through BootShim → Mu-Silicium UEFI → UniXNU → Linux. It is a
workbench, not a port: it builds and checks artefacts, and it tells you why a
boot failed. It has never booted the phone itself.

## Status, honestly

| Item | State |
|---|---|
| UFS controller + PHY in the asteroids DTS | written, compiles, **not booted** |
| Device package (`device-nothing-asteroids`) | written, checksums verified, not built by pmbootstrap |
| Initramfs dump + payload assembly | exercised against stubs and the regression suite |
| Real `mkinitfs` run | **not done** — needs an aarch64 pmOS rootfs |
| Booting through UniXNU to switch-root | **not done** — needs the phone |

## Quick start

```sh
make check && make test            # tooling is sane

# 1. kernel: enable UFS on the board DTS
git -C milos-mainline/linux apply ../asteroids-port/0001-arm64-dts-qcom-milos-enable-ufs.patch

# 2. initramfs: build it in a pmOS chroot (dump is injected automatically)
pmbootstrap chroot -r -- sh /tmp/asteroids/scripts/build-initramfs.sh --out /tmp/initramfs

# 3. payload: FAT volume with EFI/UniXNU/unixnu.toml
scripts/assemble-unixnu-payload.sh --kernel linux.efi --dtb firmware \
    --initramfs /tmp/initramfs --cmdline cmdline.txt --out payload.img
scripts/check-payload.sh payload.img

# 4. on the phone, when it fails
sh diagnose-boot.sh                # at the pmos.debug-shell prompt
```

## What is in here

| Path | Purpose |
|---|---|
| `0001-arm64-dts-qcom-milos-enable-ufs.patch` | `&ufs_mem_hc` / `&ufs_mem_phy` for `milos-nothing-asteroids.dts` |
| `a059p-fixes.patch` | fixes to your `device-nothing-asteroidspro` package |
| `pmaports/device-nothing-asteroids/` | corrected device package under the upstream codename |
| `DEVICE-PACKAGE-CHECKLIST.md` | FP6-reference values for each deviceinfo key |
| `BRINGUP-TEST-PROCEDURE.md` | first-boot procedure, stage by stage |
| `scripts/build-initramfs.sh` | drives real `mkinitfs`, injects the dump, verifies |
| `scripts/inject-boot-dump.sh` | adds the failure dump to a built initramfs |
| `initramfs/asteroids-boot-dump.sh` | the dump itself (partitions, blkid, UFS lines → framebuffer) |
| `scripts/assemble-unixnu-payload.sh` | builds the UniXNU FAT volume and `unixnu.toml` |
| `scripts/check-payload.sh` | validates kernel/DTB/initramfs; rejects a BusyBox initramfs |
| `scripts/diagnose-boot.sh` | classifies a failed boot (UFS vs rootfs lookup) |
| `scripts/ufs-layout.sh` | read-only storage survey, run on the phone |
| `scripts/rootfs-plan.sh` | turns a survey into deviceinfo + cmdline + mkfs commands |
| `scripts/cpio-tool.py` | newc cpio reader/writer, no `cpio` binary needed |
| `tests/regress.sh` | runs the whole pipeline against stubs, compares goldens |
| `ci/apk.sh` | aport checks: template drift, checksum, tarball, optional `abuild` |

## Requirements

- `python3` and `gzip` — always.
- `dosfstools` + `mtools` — payload assembly and checks (skip cleanly without them).
- `pmbootstrap` with an aarch64 rootfs — only to build a real initramfs.
- A kernel tree at `milos-7.3.y` — only to build the DTB.

## Install

```sh
make install PREFIX=/usr/local          # or DESTDIR=/pkg PREFIX=/usr for packaging
asteroids-diagnose-boot --help
```

Installs the tree under `share/asteroids-port/` with thin wrappers in `bin/`, so
the scripts keep resolving `cpio-tool.py`, `inject-boot-dump.sh` and the
initramfs fragment relative to themselves.

## Package as an APK

```sh
make apk                      # writes dist/apk/APKBUILD + the source tarball
cp dist/apk/APKBUILD dist/apk/asteroids-port-tools-0.1.0.tar.gz \
    <pmaports>/testing/asteroids-port-tools/
pmbootstrap build asteroids-port-tools
```

The APKBUILD is generated from `packaging/APKBUILD.in` with `pkgver` and
`sha512sums` taken from the tarball it just built, so the checksum always
matches the tree. Before submitting, replace the placeholder `# Maintainer:`
line at the top of the generated APKBUILD with a real name and address;
pmaports rejects placeholders. `package()` simply calls `make install`, which keeps the
packaged layout identical to a manual install: tools in `/usr/bin`,
everything else under `/usr/share/asteroids-port/`.

The aport is checked in CI by `ci/apk.sh`, which `.github/workflows/apk.yml`
runs in an Alpine container. The job regenerates the aport and fails if the
generated APKBUILD drifts from `packaging/APKBUILD.in`, if `PKGNAME`/`VERSION`
stop matching it, if a placeholder survives rendering, if `sha512sums` no
longer matches the tarball, or if the tarball picks up `dist/`, `__pycache__`,
`.git` or `.github`. It then runs `abuild`, which executes the APKBUILD's own
`check()` and `package()`, installs the resulting `.apk` into an empty root and
diffs its file list against `make install`. The integrity half needs no
Alpine and no abuild:

```sh
sh ci/apk.sh            # works on any Linux host
```

The full job, locally:

```sh
docker run --rm -v "$PWD:/src:ro" alpine:3.20 sh -euc '
  apk add --no-cache alpine-sdk mtools dosfstools python3 dtc make
  adduser -D builder && cp -a /src /work && chown -R builder /work
  su builder -s /bin/sh -c "cd /work && sh ci/apk.sh --abuild"'
```

## Tests

```sh
make test                # 27 checks, goldens in tests/expected/
make update-goldens      # after an intended message change, then review the diff
```

The suite runs a fake `mkinitfs`, fake `dmesg`/`blkid`, a fake framebuffer
target and synthetic logs through the real scripts. It catches changes to
messages, ordering, marker counts, verdicts and payload contents. It does not
prove anything about the phone.

## Bounds

- No Android/Calcite userspace work: no binder, dmabuf heaps, AVB or vendor
  modules. The goal is a mainline rootfs, not an Android device.
- `deviceinfo_flash_method="none"` and `generate_bootimg="false"` stay as they
  are until a pmOS initramfs is observed booting on hardware.
- Nothing in this tree has been validated on the device. The DTB compiles; the
  payloads assemble; the failure paths are covered by tests. That is the limit
  of what a host-side workbench can claim.
