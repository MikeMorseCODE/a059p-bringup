# Nothing Phone (3a) Pro — pmOS device package review checklist

Reference values below were read from upstream pmaports (`device/testing/`, branch
`main`) and from `milos-mainline/linux` @ `milos-7.3.y`. Use this to diff
`device-nothing-asteroids` + `linux-postmarketos-qcom-milos` in one pass.

## Status check (2026-11-05)

- Upstream pmaports `main`: **zero** paths matching `asteroid` (case-insensitive,
  whole tree). Nothing packages present: `device-nothing-spacewar`,
  `device-nothing-tetris`, `firmware-nothing-spacewar`.
- `github.com/MikeMorseCODE/pmaports` → 404. No pmaports fork on that account.
- So the aport you built is on a branch/fork/MR that isn't upstream `main` yet.
  Find it before comparing notes: `git log --oneline origin/main..HEAD -- device/testing/device-nothing-asteroids`

## deviceinfo — fields that matter, and the FP6 values they must be modelled on

`device/testing/device-fairphone-fp6/deviceinfo`:

```
deviceinfo_format_version="0"
deviceinfo_name="Fairphone (Gen. 6)"
deviceinfo_manufacturer="Fairphone"
deviceinfo_codename="fairphone-fp6"
deviceinfo_year="2025"
deviceinfo_dtb="qcom/milos-fairphone-fp6"
deviceinfo_arch="aarch64"
deviceinfo_flash_kernel_on_update="true"

deviceinfo_drm="true"
deviceinfo_chassis="handset"
deviceinfo_external_storage="true"
deviceinfo_screen_width="1116"
deviceinfo_screen_height="2484"
deviceinfo_getty="ttyMSM0;115200"

deviceinfo_flash_method="fastboot"
deviceinfo_boot_filesystem="fat32"
deviceinfo_generate_bootimg="true"
deviceinfo_flash_pagesize="4096"
deviceinfo_header_version="2"
deviceinfo_bootimg_custom_args="--os_version 99.87.36 --os_patch_level 2099-12-31"
deviceinfo_rootfs_image_sector_size="4096"
deviceinfo_super_partitions="/dev/sda12 /dev/sda12"
deviceinfo_flash_sparse="true"
```

For asteroids, the values that are *known* from the kernel tree:

| field | value | source |
|---|---|---|
| `deviceinfo_dtb` | `qcom/milos-nothing-asteroids` | `arch/arm64/boot/dts/qcom/Makefile:62` (`dtb-$(CONFIG_ARCH_QCOM) += milos-nothing-asteroids.dtb`) |
| `deviceinfo_codename` | `nothing-asteroids` (board compatible is `nothing,asteroids`) | `milos-nothing-asteroids.dts` |
| `deviceinfo_rootfs_image_sector_size` | `4096` | UFS storage, same as FP6 |
| `deviceinfo_getty` | `ttyMSM0;115200` | board DTS `stdout-path = "serial0:115200n8"`, `uart5` |
| `deviceinfo_generate_bootimg` | decide deliberately — see below | — |

Still TODO / needs your device: `deviceinfo_screen_*`, `deviceinfo_super_partitions`
(your `/dev/sdaN` numbering from the stock partition table), `deviceinfo_year`.

**Boot model.** FP6 sets `generate_bootimg="true"`, `boot_filesystem="fat32"` and
depends on `systemd-boot`. That is the UEFI/systemd-boot install path, which is
what Mu-Silicium is. Keep those three consistent: don't mix a `bootimg`-only
flow with `systemd-boot`, and don't set `deviceinfo_append_dtb="true"` (spacewar
does, but it boots a `boot.img` via fastboot and its kernel owns the DT). With
Mu-Silicium the firmware's (fixup'd) FDT must win — see the note about
`CONFIG_ARM64_APPENDED_DTB` in the main README.

## APKBUILD — dependency set, from FP6

```
firmware-fairphone-fp6-{adreno,adsp,bluetooth,cdsp,ipa,modem,vpu,wpss}
linux-firmware-ath11k
linux-postmarketos-qcom-milos
make-dynpart-mappings
mkbootimg                 # only if you keep generate_bootimg="true"
postmarketos-base
postmarketos-buffybox-unl0kr-fbforcerefresh
soc-qcom
soc-qcom-modem
soc-qcom-qbootctl
systemd-boot
makedepends="devicepkg-dev"
```

`modules-initfs` on FP6 is two lines — module *names*, no `.ko` suffix:

```
panel-novatek-nt37705
spi-geni-qcom
```

For asteroids it will be the RM69220 panel module (whatever
`CONFIG_DRM_PANEL_VXN_RM69220` is built as) plus `spi-geni-qcom` for Focaltech
touch. `kernel-cmdline.conf` on FP6 is just `console=tty0`; append your serial
console while you still need picocom.

## Kernel-side gaps verified in `milos-7.3.y`

- `drivers/gpu/drm/panel/` has `visionox-rm69299`, `rm692e5`, `vtdr6130` — **no**
  `rm69220`. The Nothing panel driver has to be carried as a patch; if it is
  `=m` it must appear in `modules-initfs`, and if `=y` the device package builds
  its own kernel, so the APKBUILD needs a `config-postmarketos-*.aarch64` that
  enables it.
- `arch/arm64/configs/fp6_defconfig` is the SM7635 config to base on. Verified
  symbols: `CONFIG_ARCH_QCOM=y`, `CONFIG_DRM_MSM=y`, `CONFIG_SCSI_UFS_QCOM=y`,
  `CONFIG_INTERCONNECT_QCOM_MILOS=y`, `CONFIG_SM_{DISPCC,GPUCC,CAMCC,VIDEOCC}_MILOS=y`.
  There is no `SM_GCC_MILOS` line in it — check what actually provides GCC
  before asserting on it in CI.
- Board DTS at `milos-7.3.y` still overrides only USB (`&usb_1`,
  `&usb_1_dwc3_hs`, `&usb_1_hsphy`); no `&ufs_mem_hc`, `&ufs_mem_phy`, `&mdss`.
  If your installed system boots from UFS and runs X11, your local tree is ahead
  of what you pushed — push that first, or the package can't be reproduced from
  source.

## firmware-nothing-asteroids — template shape (FP6)

`firmware-fairphone-fp6/APKBUILD`: `makedepends="pil-squasher"`,
`options="!check !strip !archcheck !tracedeps pmb:cross-native"`, pinned
`_commit`, `build()` runs `pil-squasher <name>.mbn <name>.mdt` over `*.mdt`,
parent package is empty, and subpackages install into
`/usr/lib/firmware/qcom/milos/<vendor>/<device>/`.

For Nothing, the same layout with `qcom/milos/nothing/asteroids/` and your
`android_vendor_nothing_asteroids` tree as `source`.
