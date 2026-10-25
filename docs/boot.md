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

U-Boot does not relocate the kernel. On a boot from a slot it passes its own
device tree in `x0`. On a `fastboot boot` `x0` is 0. Linux cannot use the
U-Boot device tree. So the shim does the work of a bootloader. See "What
U-Boot passes to the kernel".

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

### What U-Boot passes to the kernel

On a boot from a slot, the vendor U-Boot passes a device tree in `x0`. It is
`rk-kernel.dtb` of the resource in `second`, with the changes of U-Boot. It
lies at about `0xe9dba000`, below the ramdisk. U-Boot adds these parts
(measured on a UC-P10 with the stock resource):

- `/memreserve/` entries for this device tree and for the ramdisk.
- `/serial-number`, the serial number of the unit.
- `/memory`: the banks `0x200000` (size `0x8200000`) and `0xa200000` (size
  `0xede00000`).
- `/chosen`: `linux,initrd-start`, `linux,initrd-end` and `bootargs`.
- The logo and video timing properties of the display route, the address of
  the logo in its reserved memory, and a `local-mac-address` for the
  Ethernet node. That address is locally administered. It is not the MAC
  address of the `cfg` partition.

`/chosen/bootargs` has these words (values in angle brackets differ per unit
or per build):

```
storagemedia=emmc androidboot.mode=normal lcdid=1 fuse.programmed=1
dm="1 vroot none ro 1,0 ... verity 1 ..." root=/dev/dm-0
androidboot.vbmeta.device=PARTUUID=<uuid> androidboot.vbmeta.avb_version=1.1
androidboot.vbmeta.device_state=unlocked androidboot.vbmeta.hash_alg=sha256
androidboot.vbmeta.size=<size> androidboot.vbmeta.digest=<sha256>
androidboot.vbmeta.invalidate_on_error=yes androidboot.veritymode=enforcing
androidboot.verifiedbootstate=orange skip_initramfs androidboot.slot_suffix=_a
androidboot.serialno=<serial> console=ttyFIQ0 rdinit=/init
earlycon=uart8250,mmio32,0xff1a0000 swiotlb=1 androidboot.baseband=N/A
androidboot.hardware=rk30board androidboot.console=ttyFIQ0 init=/init
rootfstype=ext4
```

The `dm=` part is the verity table of `system` of the slot (from vbmeta).
`androidboot.vbmeta.device_state` follows the unlock state of the unit.

The shim copies this string into `/chosen/u-boot,bootargs` of our device
tree, so the running system can read it:

```
tr '\0' '\n' < /proc/device-tree/chosen/u-boot,bootargs
```

The kernel ignores the property, and our command line stays as it is. The
copy changes nothing in our device tree when U-Boot passed none, and when a
check fails. The code inserts the property as the first one of `/chosen`. It
reads and writes words only at aligned places, because the MMU is off.

On a `fastboot boot` U-Boot passes no device tree (`x0` is 0) and so no
command line. The kernel of a RAM boot has no `u-boot,bootargs`.

The resource in `second` is for U-Boot only. Its device tree has no PMIC
nodes. So the regulator code of U-Boot does not touch the PMIC and the
voltage regulators. This repository does not hold the resource, because it
derives from vendor files. `kernel/mkimage.sh` takes its path as a required
argument. `kernel/mkresource.py` packs a device tree into a resource. The
boot path does not use it: the image always carries the stock resource.

The kernel never reads the resource: the shim gives the kernel its own
device tree. So the resource changes only what U-Boot does. The stock
resource of the unit (`rk-kernel.dtb`, `logo.bmp` and `logo_kernel.bmp`) makes
U-Boot show the Crestron logo, as the factory image does. Every
`boot_a` image must carry the stock resource (sha256 `290ef405...`, the full
value is in [boot-control.md](boot-control.md) "The boot image rule"). U-Boot
reads `rk-kernel.dtb` from it before the tries may be counted.

The resource comes from the unit itself, so no vendor file ships. The
package `uc-pxx-kernel-lts` ships `/boot/uc-pxx-lts.img` without a resource.
On the panel, `uc-pxx-update-boot write` reads the `second` part of the stock
boot image in `boot_b`, puts it into the image and writes `boot_a`. A host
installer can run `uc-pxx-update-boot extract BOOTIMG OUT` on a dump of
`boot_b`, then `assemble TEMPLATE RES OUT`. The result is the same as
`kernel/mkimage.sh --resource RES`. The tool is in the package
`uc-pxx-boot-tools` of tsx-aports. Its review is in progress.

With the stock resource, U-Boot leaves the VOP scanning the logo when it
starts the kernel. U-Boot decodes the logo into the display pool of its
`rockchip_display` driver: 32 MiB at the top of RAM, `0xf5f00000` to
`0xf7f00000`. The device tree reserves this pool (`no-map`), so the kernel
does not write over the logo. The logo stays on the screen until
`rockchip-drm` binds at about 2.8 s and resets the VOP. A
`simple-framebuffer` does not fit: U-Boot shows the logo as a centered,
mirrored 800x1280 window, and `rockchip-drm` binds before user space starts.

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
is busybox init. It runs from RAM. It writes nothing to the eMMC. Only a
person who starts `uc-pxx-install-rootfs` or `tsx-data-restore` writes to
`system_a`.

The rescue uses the shared tools of tsx-linux-common (the package
`tsx-rescue-ui`): `tsx-rescue-status`, `tsx-confont`, `tsx-rescue-backlight`,
`tsx-rescue-login`, `tsx-data-backup` and `tsx-data-restore`. The board file
`board.sh` is the file of the root file system. It gives the model (from the
device tree) and the MAC address (from the `cfg` partition, bytes 6 to 11).

- The rescue screen. `tsx-rescue-status loop` runs on `tty1`. It shows the
  banner, the model, the kernel, eth0 (address, MAC, source of the MAC), the
  host name, the reason of the rescue and the A/B state. The A/B state is
  the output of `uc-pxx-bootctl status` (it reads the sector and changes
  nothing). The screen shows a progress bar while `uc-pxx-install-rootfs`
  runs. Enter on a USB keyboard opens a root shell on the screen.
  `tsx-confont` loads the largest Terminus font that gives 80x25 cells. On
  the turned panel (`fbcon=rotate:3`) the console is 1920x1200 and the font
  is 16x32 (120x37 cells).
- The backlight is set to `TSX_RESCUE_BACKLIGHT` percent (50).
- The blue LED blinks fast (250 ms on, 250 ms off) in the rescue system. During
  the normal boot it blinks slowly (500 ms on, 1500 ms off), see
  [leds.md](leds.md) "The boot timeline of the blue LED".
- A root shell on the serial console `ttyS2` (115200 baud). It needs no
  login.
- In the background: the MAC address of eth0, the switch init with
  `rtl8363-init`, DHCP on eth0.
- SSH with dropbear on port 22. `tsx-rescue-login` chooses the login at each
  rescue boot:
  1. The login of the panel. It reads `data/tsx/panel.conf` and
     `root/.ssh/authorized_keys` of the root file system (label `tsxroot`,
     read only). The key of root becomes the key of the rescue. A
     `ROOT_PASSWORD_HASH` in `panel.conf` becomes the password of root.
  2. A one-time password, if the root file system has no key and no hash.
     Only the rescue screen shows it. It is not in the log.
  3. Test builds only: the password hash or the key that the build baked in
     (`TSX_DEV_RESCUE_HASH`, `TSX_DEV_RESCUE_KEYS`).
  A normal build has no root password and no key.
- The reason is in `/run/rescue-reason` (a copy of
  `/run/uc-pxx-rescue-reason`). The log is `/run/uc-pxx-rescue.log`.

The tools in the rescue:

| Tool | Task |
|---|---|
| `uc-pxx-install-rootfs` | Writes a `rootfs.ext4` into `system_a` (`mmcblk0p22`, GPT name `system_a`). Nothing else |
| `tsx-data-backup`, `tsx-data-restore` | Back up and restore the panel data. The unit has no data partition, so it works on the root file system (`/data`, `/root`, `/home`, `/var/lib/...`) |
| `uc-pxx-bootctl status` | Shows the A/B state |
| `uc-pxx-reboot loader` | Restarts into the loader (download) mode. See "The loader mode" |
| `uc-pxx-reboot fastboot` | Restarts into the fastboot mode of U-Boot. See "Restart into a U-Boot mode" |

`uc-pxx-install-rootfs` does a preflight first and stops at the first
failed check: the partition is `mmcblk0p22`, on the eMMC, exactly 1792 MiB,
not mounted, and slot B is successful with priority 1 to 14. It writes the
image, reads it back and compares the sha256 value, checks the label
`tsxroot`, runs `e2fsck` and grows the file system. The progress shows MiB,
percent, rate and the time left. The rescue does not write `boot_a`, the A/B
metadata (misc LBA 49156), the idbloader or the partition table. Write
`boot_a` on the running system with `uc-pxx-flash-boot`.

From a host, with the rescue address `<ip>`:

```
ssh root@<ip> uc-pxx-install-rootfs --check
ssh root@<ip> uc-pxx-install-rootfs --size <bytes> <sha256> < rootfs.ext4
```

The rescue system never marks the boot as good. So slot A stays "trying".

If `switch_root` itself fails, PID 1 ends. The kernel then restarts the unit
after 30 seconds (`panic=30` on the command line). That boot counts as a
failed try of slot A.

Other options of the kernel command line: `uc-pxx.rootwait=N` (seconds,
default 15) and `uc-pxx.init=PATH` (default `/sbin/init`).

The build takes the tools from a checkout of tsx-linux-common (`TSX_COMMON`),
the reviewed `uc-pxx-bootctl` (`UC_PXX_BOOTCTL`, checked by its sha256),
`uc-pxx-reboot-syscall` (`UC_PXX_REBOOT`, `tools/uc-pxx-reboot/build.sh`) and
`RTL8363_INIT` (the tool of `tools/rtl8363-init`, built with the Realtek SDK)
as files. This repository holds none of them.

### The loader mode

The stock Android system handled the key combination Volume down + Mute (the
download or loader mode of the Rockchip tools). U-Boot does not. So mainline
does it. The keys are touch keys of the maXTouch controller: `KEY_MUTE` (113)
and `KEY_VOLUMEDOWN` (114), see `rootfs/overlay/etc/tsx/buttons-board.conf`.
The code reads the key state with `evtest --query` (EVIOCGKEY), because
`tsx-idled` grabs the input devices.

How to use it:

1. Wait until the TSX - LINUX splash shows.
2. Press Volume down and Mute together, and hold both keys for 3 s.
3. The unit stops the services and restarts into the loader mode. A host sees
   the rockusb device (`2207:330c`).

The keys work only in the boot window and in the rescue system. They do
nothing in daily use, so a long press can never restart the panel.

- `/init` checks the keys once, early. If both are down, it shows the line
  "Loader mode: keep holding Vol- and Mute". After 3 s it shows "Loader mode:
  restarting" and runs `uc-pxx-reboot loader`. With no key down the check adds
  no delay. If a key is released, the boot goes on.
- The service `uc-pxx-loader-key` (sysinit runlevel) watches from the start of
  OpenRC until 60 s of uptime. It needs only the input device node, so it
  starts before udev and does not wait for udev-settle. It needs both keys
  down for 3 s. At 60 s it ends with exit 0 and logs the end. It has no
  supervisor, so nothing starts it again. A hold that is in progress at 60 s
  gets its 3 s. The log is `/run/uc-pxx-loader-key.log` and the kernel log.
- The rescue system runs the same program with `--rescue` (a respawn line of
  the rescue `inittab`). It has no end time for the whole session, because the
  rescue is a recovery state. It needs the same 3 s hold.
- `uc-pxx-reboot loader` restarts with the argument `loader`. The device
  tree turns it into `BOOT_BL_DOWNLOAD`, and the vendor U-Boot enters the
  download mode (rockusb). See "Restart into a U-Boot mode". On the running
  system it does a clean shutdown first. In `/init` and in the rescue it
  restarts at once.
- Nothing is written to the eMMC. A power cycle leaves the loader mode.

The calibration limit: the touch controller calibrates when its driver probes
(about 2.4 s after the kernel start). A finger that is on a key at that time
becomes the zero level, and the key reads "up" until the finger is lifted and
put down again. So a press that you hold from the power-on is never seen. Press
the keys after the splash shows. If you held the keys from the power-on, lift
both and press them again.

Measured on a unit: with both fingers down, both keys read down. After the
driver was bound again with the fingers still on the keys, both read up.

The first test of the new boot window needs a unit: press the keys after the
splash and look for the rockusb device on the USB-C port of a host.

### Restart into a U-Boot mode

The vendor U-Boot reads the boot mode register `PMUGRF_OS_REG0` (PMU GRF,
offset `0x300`) at each start. The device tree node `reboot-mode`
(`syscon-reboot-mode`) writes the register when Linux restarts. The values
are the ones of the stock device tree:

| Restart argument | Value | U-Boot |
|---|---|---|
| none (a plain `reboot`) | `BOOT_NORMAL` (`0x5242c300`) | Boots the slot |
| `loader`, `bootloader` | `BOOT_BL_DOWNLOAD` (`0x5242c301`) | Download mode (rockusb, `2207:330c`) |
| `fastboot` | `BOOT_FASTBOOT` (`0x5242c309`) | Fastboot (`18d1:d00d`). Its log says "boot mode: bootloader" |
| `recovery` | `BOOT_RECOVERY` (`0x5242c303`) | Not tested |

`bootloader` means rockusb here, as in the stock Android system. U-Boot does
not clear the register when it enters fastboot. So `fastboot reboot` comes
back into fastboot. A kernel that `fastboot boot` started has the value too,
and the `BOOT_NORMAL` value of its next plain reboot clears it. A power cycle
also clears the register. The node has `mode-fastboot` since the kernel
commit "Add mode-fastboot to the reboot-mode node" of `uc-pxx-lts`.

The busybox `reboot` has no argument, and a plain reboot writes
`BOOT_NORMAL`. So a register write before `reboot` has no effect. Use
`uc-pxx-reboot loader` or `uc-pxx-reboot fastboot` (the script
`/usr/sbin/uc-pxx-reboot`). It stops the system cleanly:

1. It writes the mode to `/run/uc-pxx-reboot.mode` and runs `reboot`.
2. busybox init runs the shutdown lines of `/etc/inittab`. `openrc
   shutdown` stops the services, ends the other processes and remounts the
   file systems read-only. The rescue system runs `umount -a -r` instead.
3. The last shutdown line, `uc-pxx-reboot --pending`, reads the mode file
   and runs `/usr/libexec/uc-pxx-reboot-syscall MODE`. That small static
   program calls `sync` and `reboot(2)` with `RESTART2` and the argument.
   With no mode file the line does nothing, and init restarts as usual.

In `/init` of the initramfs, PID 1 is the `/init` script and nothing of the
eMMC is mounted. There `uc-pxx-reboot` runs `uc-pxx-reboot-syscall` at
once. It does the same when `/etc/inittab` has no `--pending` line. busybox
init reads `/etc/inittab` only at the start. So after an update that adds
the line, the clean path works after the next boot.

`uc-pxx-reboot-syscall` takes only `loader` and `fastboot`. Do not run it by
hand on a running system: it stops no service. Nothing is written to the
eMMC. The source is `tools/uc-pxx-reboot/uc-pxx-reboot-syscall.c`.

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

Between the reset of the VOP and the first frame of the splash (about 1 s),
the LCD gets no picture. The first `tsx-splash show` sets the mode, so the
panel starts again with a black frame, and the splash follows.

The panel is 1200x1920 and is mounted turned (`fbcon=rotate:3`). `tsx-splash`
reads this number from the command line and turns the landscape frame onto
the panel. It draws the largest image that fits, centered on black. `/init`
always draws the landscape frame (`-o landscape`). The only image is the
1280x800 image of the package, in the initramfs and in the root file system.
It is centered on the 1920x1200 frame. The scale of the kiosk is 1.5, so the
picture has the physical size that it has on the TSW 10" panels. A larger
image (1920x1200 and 1200x1920) was too big on the screen.

The variable `UC_PXX_SPLASH_SIZES` (sizes `WxH` separated by spaces, empty by
default) is the hook for another size. The build renders each size with
`splash/mksplash.sh` of tsx-linux-common (`TSX_COMMON`, default
`../tsx-linux-common`) and puts it next to the image of the package.
`tsx-splash` then draws the largest image that fits.

`rockchip-drm` gives `fb0` a shadow buffer in system memory. The kernel
copies the changed lines to the scanout buffer. `tsx-splash` writes one line
per `write()`. Kernel 6.18 computed a clip of zero width for a write that
ends at the end of a line, so the full-screen `show` never reached the
screen, and only the status band was visible. The kernel carries the
upstream fix "drm/fb-helper: Fix clipping when damage area spans a single
scanline".

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
