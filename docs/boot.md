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

The kernel never reads the resource: the shim gives the kernel its own
device tree. So the resource changes only what U-Boot does. The stock
resource of the unit (`rk-kernel.dtb`, `logo.bmp` and `logo_kernel.bmp`) makes
U-Boot show the Crestron logo, as the factory image does. The installer
must take that resource from the unit itself at install time: it reads the
`second` part of the stock boot image in `boot_b` (the sizes and the page
size come from the boot image header) and gives the file to
`kernel/mkimage.sh --resource`. So no vendor file ships. This installer
step is not written yet.

The build token is the same string in two places: the name field of the boot
image header, and the word `uc-pxx.id=TOKEN` that `kernel/mkimage.sh` adds to
`/chosen/bootargs` of the embedded device tree. The boot-marking hook reads
the token from the kernel command line. It uses the token to check that the
running kernel is the image in the slot. See
[boot-control.md](boot-control.md).

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

## The boot initramfs

The initramfs is built into the kernel Image. `rootfs/build-rootfs.sh
initramfs` makes it as the uncompressed cpio archive
`rootfs/out/initramfs.cpio`. The sources are in `rootfs/initramfs/`.
`/init` does these steps:

1. Mount `/proc`, `/sys`, `/dev` and a tmpfs on `/run`.
2. Find the root partition: the partition with the GPT name `system_a`. If
   no partition has this name, the eMMC partition with the label `tsxroot`.
   Wait up to 15 seconds for it.
3. Stop with the rescue system if the partition does not hold an ext4 file
   system with the label `tsxroot`. The script never checks, grows or mounts
   another file system.
4. Check the file system with `e2fsck -p`. If that cannot fix it, run
   `e2fsck -y`. If that also fails, start the rescue system.
5. Grow the file system to fill the partition, if the partition is more than
   64 MiB larger. A new `rootfs.ext4` is smaller than `system_a`.
6. Mount the file system read-write on `/newroot`.
7. Move `/dev`, `/proc`, `/sys` and `/run` into it and run `switch_root` to
   `/sbin/init`.

`/run/uc-pxx-initramfs.log` keeps the messages of these steps. The kernel log
has them too, with the prefix `uc-pxx-initramfs:`. The root file system gets
the logs of e2fsck and resize2fs in `/var/log/initramfs-fsck.log` and
`/var/log/initramfs-resize.log`.

The initramfs never writes the A/B metadata, a boot partition or the
partition table. It does not read or change `uc-pxx.id=` on the kernel
command line. The boot-marking hook of the root file system reads it.

### The rescue system

`/init` starts the rescue system when a step fails, when the kernel command
line has `uc-pxx.rescue`, or when the root file system has the file
`/etc/uc-pxx-force-rescue` (the script removes the file). The rescue system
is busybox init. It runs from RAM and writes nothing to the eMMC.

- A root shell on the serial console `ttyS2` (115200 baud). It needs no
  login.
- In the background: the MAC address of eth0 from the `cfg` partition (read
  only), the switch init with `rtl8363-init`, DHCP on eth0.
- SSH with dropbear on port 22 with key login only, if the build had
  `AUTHORIZED_KEYS`. Without a key, no SSH starts.
- The reason is in `/run/uc-pxx-rescue-reason`. The log is
  `/run/uc-pxx-rescue.log`.

The rescue system never marks the boot as good. So slot A stays "trying".

If `switch_root` itself fails, PID 1 ends. The kernel then restarts the unit
after 30 seconds (`panic=30` on the command line). That boot counts as a
failed try of slot A.

Other options of the kernel command line: `uc-pxx.rootwait=N` (seconds,
default 15) and `uc-pxx.init=PATH` (default `/sbin/init`).

The build takes `RTL8363_INIT` (the tool of `tools/rtl8363-init`, built with
the Realtek SDK) and `AUTHORIZED_KEYS` as files. This repository holds
neither of them.

### The boot splash

The command line has `fbcon=map:1`. The framebuffer console then maps to a
framebuffer that does not exist, so no console text reaches the LCD.
`tsx-splash` (package `tsx-splash` of tsx-linux-common) owns `fb0`:

1. `/init` waits up to 3 seconds for `/dev/fb0`. `rockchip-drm` makes it
   when it has bound the panel.
2. `/init` draws the splash with the status line "Starting", as soon as `fb0`
   exists. If `fb0` comes later, `/init` draws it while it waits for the
   root partition, or before `switch_root`.
3. The splash stays on the screen until the compositor of the kiosk takes the
   display.

The panel is 1200x1920 and is mounted turned (`fbcon=rotate:3`). `tsx-splash`
reads this number from the command line and turns the landscape frame onto
the panel. It draws the largest image that fits, centered on black. `/init`
always draws the landscape frame (`-o landscape`). So the initramfs holds two
images: 1920x1200 for the UC-P10 and the 1280x800 image of the package for
the UC-P8. The root file system also gets 1920x1200 and 1200x1920 (portrait)
next to the images of the package. `splash/mksplash.sh` of tsx-linux-common
renders these sizes at build time, because the package does not have them.
The build finds the checkout in `TSX_COMMON`, or next to this repository.
Without it the UC-P10 shows the 1280x800 image, centered on black.

The rescue system and the console profile (`/etc/tsx/profile` is `console`,
with a login on `tty1`) get the text console back first: `tsx-splash
console` maps the console to `fb0`, and `/init` sets the rotation of the
console from `fbcon=rotate:N`. `vt.global_cursor_default=0` hides the cursor.
The kernel has no boot logo.

`rootfs/build-rootfs.sh initramfs` installs `tsx-splash` from the apk tree
`TSX_APK_LOCAL` (`<ALPINE>/common`). apk checks the package with the key of
the image. Without `TSX_APK_LOCAL` the initramfs has no splash, and the LCD
stays dark until the kiosk starts.

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
Bluetooth come from it today. See "Firmware" in [rootfs.md](rootfs.md).
