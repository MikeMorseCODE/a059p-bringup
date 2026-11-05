# First boot of the UniXNU payload: bring-up test procedure

For the Nothing Phone (3a) Pro (A059P) running postmarketOS through
BootShim → Silicium UEFI → UniXNU → Linux. Written to be run once, in order,
with a pen. Every stage below has a signature line you can see on the console
and a single next action if that line never appears.

## 0. Before you flash anything

```sh
sh scripts/check-payload.sh payload.img     # must end "payload is coherent"
```

- [ ] `check-payload.sh` exits 0. A `[FAIL]` there means do not flash: fix the payload first.
- [ ] Cmdline contains `console=tty0 console=ttyMSM0,115200n8 pmos.debug-shell`.
      `pmos.debug-shell` is what guarantees you get a shell even when the rootfs
      is missing, so the first boot is never blind.
- [ ] The rootfs is formatted with `-L pmOS_root` (that is the label the
      initramfs searches for; without it boot stops at stage 4 no matter how
      healthy UFS is).
- [ ] The initramfs has the failure dump injected. `build-initramfs.sh` does
      this itself and fails if it cannot; `assemble-unixnu-payload.sh` warns
      when the initramfs it is given lacks it, and `check-payload.sh` reports
      it either way. With it, a failed boot prints its own evidence to the
      screen (section 3a).
- [ ] The previously working image is still on disk. You will want it back if
      the new payload dies before stage 2.

## 1. Console

Two channels, use both:

- **UART** — `ttyMSM0` at 115200. Per the board DTS, `UART_RX`/`UART_TX` are
  routed to test points on the board, not to the USB connector, so this needs
  physical access. It is the only channel that survives a kernel that dies
  before USB comes up.
- **USB ACM** — comes up once the initramfs runs `setup_usb_network`, so it is
  useless for stages 0–2 but perfect for the debug shell.

If the panel lights up you also get `tty0` (fbcon) from the EFI framebuffer,
which is enough to read a panic but painful to type into.

## 2. Stage table

Strings in the table are patterns, not verbatim literals: the initramfs
substitutes the real device, filesystem type and version at runtime
(`Detected $type filesystem`, `Mount root partition ($partition) to /sysroot`,
`initramfs version: $INITRAMFS_PKG_VERSION`).

| # | Look for on the console | If it never appears |
|---|---|---|
| 0 | `UNIXNU:` lines, then the menu, then your `postmarketOS` entry booting | Payload volume is wrong: no `EFI/UniXNU/unixnu.toml`, or the entry paths do not resolve. `check-payload.sh` catches both. |
| 1 | `Booting Linux on physical CPU`, `Linux version 7.x`, and a `Memory:` total that matches the installed RAM | Kernel did not start. Either the EFI stub never ran (wrong kernel file) or the DTB has no usable `/memory`. Boot with `dtb = "firmware"` to separate the two. |
| 2 | `❬❬ PMOS STAGE 1 ❭❭` followed by `initramfs version: ...` | The initrd never reached the kernel, or there is no `/init`. This is the "BusyBox image" trap: a non-pmOS initramfs also prints nothing here. Check the payload's `initrd` key resolves and the archive has `/init`. |
| 3 | Either a shell prompt (debug shell) or `Waiting for super partition ...` | Stage 1 ran but stage 2 did not: `/init_2nd.sh` or `/init_functions.sh` missing from the archive. |
| 4 | `Mount root partition (/dev/sdaN) to /sysroot (read-write) ...` then `Detected ext4 filesystem` | Boot stopped at root discovery. Run `diagnose-boot.sh` (below) — this is the fork in the road. |
| 5 | `Switching root` | Rootfs mounted but pivot failed: look for the init binary in the rootfs, or a mount option problem. |

Anything before stage 2 that stops with `Kernel panic - not syncing: No working
init found` means the kernel is fine and the initramfs is not — go back to
`check-payload.sh`, not to the device tree.

## 3. At the debug shell

`pmos.debug-shell` drops you to a shell *before* `wait_root_partition`, so it
works even when there is nothing to mount. Run the classifier first; it reads
`dmesg`, `/proc/partitions` and `blkid` and prints one verdict:

```sh
sh diagnose-boot.sh
```

Verdict codes, and what each one means:

| Code | Verdict | Belongs to |
|---|---|---|
| 10 | UFS driver never bound | device tree / kernel config |
| 11 | Controller found, link did not come up (phy, regulator, clock) | device tree supplies, regulator driver |
| 12 | UFS probed but no SCSI disk appeared | phy node not enabled, or link timeout |
| 13 | Disk present, no partitions | GPT not parsed, or no partition table |
| 14 | Disk and partitions fine, no `pmOS_root` label | initramfs / rootfs side |
| 15 | Rootfs found, mount failed | filesystem type or sector size |
| 0 | Rootfs mounted | failure is after mount |

Evidence worth capturing while you are there:

```sh
cat /proc/cmdline                      # did the args from unixnu.toml arrive intact?
cat /proc/partitions                   # is /dev/sda there, and its children?
blkid                                  # LABEL/TYPE for every partition
ls -l /dev/disk/by-partlabel           # Android names: super, userdata, boot_a...
dmesg | grep -iE 'ufs|qmp|scsi'        # controller, phy, link, timeouts
cat /sys/kernel/debug/regulator/regulator_summary   # if it exists: which rails are on
sh ufs-layout.sh                       # the full storage survey from the rootfs task
```

## 3a. The screen tells you what happened

With the dump injected, every failure path (`wait_partition`,
`mount_root_partition`, `initramfs-extra` lookup) writes a block like this to
`/dev/tty0` before halting, so you do not need serial to triage:

```
================ pmOS boot failure ================
uptime: 12.4s
model : Nothing Phone (3a) Pro
cmdline: console=tty0 console=ttyMSM0,115200n8 pmos.debug-shell
codename: nothing-asteroids

--- ufs / phy / scsi (last 20) ---
...
--- /proc/partitions ---
...
--- blkid ---
...
--- /dev/disk/by-partlabel ---
...
===================================================
 VERDICT: DISK AND PARTITIONS OK, NO pmOS_root LABEL - format with -L pmOS_root
 Photograph this screen; press the volume key to
 beep, then attach USB for the debug shell.
===================================================
```

The verdict line maps onto the codes in section 3: no `sd` disk at all → 10/11,
disk without children → 13, partitions without the label → 14, label present →
the mount or the rootfs. The device beeps when it halts, so you can tell a
failed boot from a dead one with the phone in your pocket.

## 4. Telling UFS failure from rootfs-lookup failure

This is the question the whole procedure exists to answer, and the two look
almost identical from the last screenful of output. Use the disk, not the log:

**UFS never came up** if any of these is true:

- `cat /proc/partitions` shows no `sda` at all.
- `dmesg | grep -i ufshcd` is empty (driver never bound → verdict 10), or shows
  `ufshcd_pltfrm_init() failed` / `Failed to get PHY` with `-517`
  (`-EPROBE_DEFER`: a supply or clock never appeared → verdict 11).
- `ls /dev/sd*` finds nothing.

Fix belongs in the DTS or the kernel config: `&ufs_mem_hc` and `&ufs_mem_phy`
both `status = "okay"`, `CONFIG_SCSI_UFS_QCOM=y`, and the rails
`vreg_l12b` (vcc) / `vreg_l4f` (vccq2) / `vreg_l2b`, `vreg_l4b` (phy).

**Rootfs lookup failed** if all of these are true:

- `/dev/sda` exists and has children (`sda1`, `sda12`, ...).
- `blkid` lists those partitions but none carries `LABEL="pmOS_root"`.
- The log says `root partition not found!` — `wait_partition` emits it as
  `splash_set_error "$description partition not found!"` with `description`
  set to `root`, so the wording is assembled at runtime.

Fix belongs on the rootfs side: format with `mkfs.ext4 -L pmOS_root`, or — if
the rootfs lives inside the Android `super` partition — check that
`deviceinfo_super_partitions` is set and that `make-dynpart-mappings` is
actually in the initramfs (`check-payload.sh` prints an info line when it is
missing).

One more case that is neither: **partitions exist, disk exists, and blkid shows
a `pmOS_root` label, but the mount fails**. Then it is the filesystem, not the
storage: `ERROR: unable to mount root partition!` or
`ERROR: Detected unsupported '<type>' filesystem`. ext4 is built into the kernel;
f2fs is a module and has to be inside the initramfs.

## 5. Getting the log off the phone

At the debug shell, with USB attached:

```sh
dmesg > /tmp/dmesg.txt
cp /tmp/dmesg.txt /sysroot/ 2>/dev/null || true
# or over the initramfs' USB network (unudhcpd runs on the phone):
#   host: nc <phone-ip> 24 > dmesg.txt     (busybox nc on both ends)
```

If nothing works, photograph the screen: the last ten lines plus
`cat /proc/partitions` are enough to pick the verdict.

## 6. Record sheet

One row per attempt, because the differences between attempts are the data:

| Attempt | payload sha256 | cmdline | last line seen | verdict | change made |
|---|---|---|---|---|---|
| 1 | | | | | |

## 7. Getting back

The known-good image (`boot-3a-pro-linux73-console.img`,
`fdd1d848f2d6aedf251aa73fb5e27cddf14467cf244b26130c3afa81fb2b59b7`) still boots
the phone. Flash it back before you start debugging, not after — a payload that
dies in stage 0 leaves you with no console at all, and re-flashing blind is how
a device ends up in a worse state than the bug it was testing.
