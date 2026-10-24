# Boot chain and slots

This page tells how the UC-P10 starts, what the boot image holds, and how the
eMMC is used in each phase. Read it before you write anything to a unit.

## Rules for a unit

- Secure boot is fused on. There is no software recovery from a state with
  zero bootable slots.
- At every moment, at least one A/B slot must stay bootable. Never write
  something that can leave zero bootable slots, even for a short time.
- Treat a write to the A/B metadata, the idbloader, the partition table, or
  the `uboot` and `trust` partitions of the only bootable slot as
  irreversible.
- Never write `uboot_a` or `uboot_b`. Both hold the vendor U-Boot.
- Before you write, make a backup, check the payload and keep a bootable
  fallback. After you write, read the data back and compare it.

## The boot chain

1. The BootROM loads the idbloader from the eMMC.
2. The idbloader starts the vendor U-Boot. It is a userdebug build and shows
   the orange boot state.
3. U-Boot reads the A/B metadata and picks a slot.
4. U-Boot loads the Android boot image of that slot (`boot_a` or `boot_b`)
   and runs its kernel entry.
5. The kernel entry is the shim. The shim copies the Linux Image to its
   final address and starts it with the device tree.
6. Linux unpacks the built-in initramfs and runs `/init`.
7. The initramfs mounts the root file system of the slot, and OpenRC starts
   the services.

U-Boot does not relocate the kernel and passes no device tree (register `x0`
is 0). So the shim does the work of a bootloader.

## The boot image

The boot image is an Android boot image of header version 0 with a page size
of 2048 bytes. It has these parts:

| Part | Content |
|---|---|
| kernel | The shim: a stub, the device tree and the Linux Image |
| ramdisk | A dummy file of 20 bytes. The real initramfs is built into the Image |
| second | A Rockchip resource (RSCE) with the device tree for U-Boot |
| board | The build token (up to 15 characters) |
| cmdline | Not used by the kernel |

The shim is a valid arm64 Image with the stub at offset 0, the device tree at
64 KiB and the Linux Image at 2 MiB. The stub runs from the address where
U-Boot loaded it. It copies the Linux Image to `0x4000000` (2 MiB aligned),
prints progress on UART2 and jumps to Linux with the device tree address in
`x0`. The source is `bootloader/shim.S`.

The kernel command line comes from the device tree node `/chosen/bootargs`.
The shim hands its own device tree to Linux, so the command line in the image
header has no effect.

The resource in `second` is for U-Boot only. Its device tree has no PMIC
nodes. So the regulator code of U-Boot does not touch the PMIC and the
voltage regulators. This repository does not hold the resource, because it
derives from vendor files. `kernel/mkimage.sh` takes its path as a required
argument. `kernel/mkresource.py` packs a device tree into a resource.

The build token is the same string as `/etc/uc-pxx-build-id` in the built-in
initramfs. The boot-marking hook uses it to check that the running system is
the image in the slot. See [boot-control.md](boot-control.md).

### Size limits

- The image must not be larger than 64 MiB. The boot descriptor of `vbmeta_a`
  on the unit that we used has this value as the image size. A larger image
  is truncated by libavb. TODO: check how an install sets this value on a new
  unit.
- The Linux Image must end below the secure OS at `0x8400000`. A larger
  Image is a build error in `kernel/mkimage.sh`.
- The copy must not overlap its source. `kernel/mkimage.sh` checks this for
  a boot from the partition (stub at `0x280000`) and for a boot from RAM
  (stub at `0xa200800`).

## A/B metadata

The slot state is a libavb AvbABData structure in the `misc` partition at LBA
49156. Its CRC is stored big-endian. A wrong byte order gives the error "No
bootable slots". Only the reviewed boot-control tool may write it.
[boot-control.md](boot-control.md) tells the plan for that tool.

## Phases

### Phase 1: mainline on slot A, Android on slot B

| Partition | Use |
|---|---|
| `boot_a` | The uc-pxx boot image |
| `system_a` (1792 MiB) | The root file system, ext4, label `tsxroot` |
| `vendor_a` (384 MiB) and `oem_a` (1024 MiB) | One LVM physical volume each. Together they hold the volume group `tsx` |
| `boot_b`, `system_b` and the others of slot B | Stock-based Android userdebug, not changed. It is the fallback and the rescue |

`/data` is the logical volume `tsx/data` (ext4, label `tsxdata`).

An update writes only slot A. The flash wrapper sets slot A to the state
"trying" before it writes `boot_a`. A boot that never gets marked as good
runs out of tries, and U-Boot starts slot B.

### Phase 2: mainline on both slots

| Partition | Use |
|---|---|
| `boot_a`, `system_a`, `boot_b`, `system_b` | The uc-pxx boot image and root file system of each slot |
| `userdata` (6701 MiB) | `/data`, shared by both slots |

An update writes the inactive slot, sets it to "trying" and reboots into it.
After a healthy boot the boot-marking hook marks the new slot as good. A
failed update runs out of tries, and U-Boot starts the other slot.

Phase 2 needs a boot-control tool that works on both slots. That needs a new
review. Slot B gets mainline only after slot A ran in phase 1 without faults.
At every step one slot must stay bootable.

The vendor partition is gone in phase 2, and the firmware files for Wi-Fi and
Bluetooth come from it today. See "Firmware" in rootfs.md.
