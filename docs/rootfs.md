# Rootfs and userland

The UC-P10 runs a small Alpine Linux root file system. A build host makes it
as an ext4 image for `system_a`. This page tells how the image is built, what
the board files and services do, and what is still open. For the boot chain
see [boot.md](boot.md), for the kernel see [kernel.md](kernel.md), and for the
board see [hardware.md](hardware.md).

The userland is the one of the sister projects tsx-xx70-linux and
tsx-xx60-linux. Its parts that do not depend on the hardware (kiosk, panel
configuration, setup page, Home Assistant device, updates, screen blanking,
data partition) are the packages of tsx-linux-common. This repository holds
the parts that belong to the UC-P10.

## Build the image

```sh
rootfs/fetch-apk-tree.sh apk-tree      # the published apk tree (common and uc-pxx packages)
TSX_APK_LOCAL=$PWD/apk-tree rootfs/build-rootfs.sh rootfs   # out/rootfs.{tar.gz,ext4,manifest,sizes,sha256}
```

`rootfs/mkrootfs.sh` builds the rootfs inside an aarch64 Alpine container
under qemu-user (binfmt `qemu-aarch64`) on the build host. So the result is
native aarch64 code. Never run the build on the workstation.

The image comes from packages only. The build compiles nothing and copies no
software from the repository. `TSX_APK_LOCAL` is required. It names a local
copy of the published tree of the apk repository (tsx-aports).

The build does these steps:

1. Check the tree (`rootfs/check-apk-tree.sh`).
2. Install the Alpine packages of `rootfs/packages.txt`, the packages of
   `rootfs/packages-tsx.txt` and the profile package `uc-pxx-<profile>`.
3. Copy the image files of `rootfs/profiles/image.list` (`fstab`, `inittab`
   and the profile marker).
4. Add the users, enable the services of the profile and lock the root
   password.
5. Check the kernel package against the pin (`rootfs/check-kernel-pins.sh`).
6. Write the tarball and the ext4 image (label `tsxroot`).

`rootfs/out/rootfs.ext4` must be at most 1700 MiB. `system_a` has 1792 MiB.
The initramfs grows the file system to fill the partition at the first boot.

The initramfs is built into the kernel Image. It is not made here
([kernel.md](kernel.md)).

## Where the packages come from

The apk repository is `tsx-aports`. The UC-P10 uses two categories: `common`
for the shared packages and `uc-pxx` for the packages of this family. A panel
lists only these two repositories.

| Package | Content |
|---|---|
| `uc-pxx-board` | The board files of this repository (`rootfs/overlay`) and `rtl8363-init` |
| `uc-pxx-kernel-lts` | The boot image `/boot/uc-pxx-lts.img` and the module tree |
| `uc-pxx-boot-tools` | The boot-control tools ([boot-control.md](boot-control.md)) |
| `uc-pxx-console`, `uc-pxx-kiosk`, `uc-pxx-ha` | The profile meta packages |

The board package and the profile packages are private. The published tree
does not hold them. `rootfs/check-apk-tree.sh` stops the build and names the
missing packages.

The board needs the commits of tsx-linux-common that add `TSX_PKG_PREFIX` and
the board hook. They are not in a tagged release yet. Use no older common.

TODO: the category `uc-pxx` does not exist in tsx-aports yet. The packages
above are not written. The files in `rootfs/overlay` are the sources of
`uc-pxx-board`.

## Profiles

A profile decides what the image holds. `rootfs/profiles/*.list` name the
packages, services, users and build steps. Each profile holds all the earlier
ones.

| Profile | Adds |
|---|---|
| `console` | A plain Linux system with a text login on the panel screen and SSH |
| `kiosk` | The Chromium kiosk, screen blanking, the on-screen keyboard and the setup page |
| `ha` (default) | The Home Assistant layer: ESPHome device, MQTT, voice satellite, Bluetooth proxy, Sendspin |

`rootfs/profile.sh` reads the lists. `mkrootfs.sh` and
`rootfs/tests/test-profiles.sh` both use it.

## Root login

A public image has no root password. The field in `/etc/shadow` is locked. The
installer sets a password or an SSH key. A test build can set a fixed password
with `TSX_DEV_ROOT_HASH`. Never publish such an image.

## Partitions and file systems

| Mount | Source | Note |
|---|---|---|
| `/` | `system_a`, ext4, label `tsxroot` | Grown to fill the partition by the initramfs |
| `/data` | ext4, label `tsxdata` | Phase 1: the LVM volume `tsx/data` over `vendor_a` and `oem_a`. Phase 2: `userdata`. `nofail` |
| `/tmp` | tmpfs | |

The service `uc-pxx-lvm` activates the volume group `tsx` before `/data` is
mounted. [boot.md](boot.md) tells the phases.

## Board values

`rootfs/overlay/usr/local/lib/tsx/board.sh` holds the values and the small
functions that the shared scripts read. The main values:

| Name | Value |
|---|---|
| `TSX_FAMILY`, `TSX_APK_CATEGORY`, `TSX_PKG_PREFIX` | `uc-pxx` |
| `TSX_SOUND_CARD` | `UCP10` |
| `TSX_DISPLAY_DRM`, `TSX_RENDER_DRM` | `rockchip`, `panfrost` |
| `TSX_SERIAL_CONSOLE` | `ttyS2` |
| `TSX_MAC_SOURCE` | `cfg` |

`tsx-autoupdate` builds the package names `$TSX_PKG_PREFIX-board` and
`$TSX_PKG_PREFIX-kernel*`. This board sets `TSX_PKG_PREFIX=uc-pxx`. The
variable and the board hook need a tsx-linux-common that has them (see the
note in "Where the packages come from").

The function `tsx_board_pre_update` is the board hook of `tsx-autoupdate`. It
runs `uc-pxx-arm-slot` before `apk upgrade` changes the system
([boot-control.md](boot-control.md) "The update rule").

### MAC address

The MAC address of eth0 is in the `cfg` partition, in bytes 6 to 11. The
function `tsx_board_mac` reads exactly these six bytes with `dd`. It never
writes the partition and never copies it, because the partition also holds a
private key. An address is valid if it is not all zeros, not all ones, and a
globally administered unicast address.

### Model

The model comes from the compatible string of the device tree. The value
`crestron,uc-p10` gives UC-P10, and `crestron,uc-p8` gives UC-P8.

## Services

All services of this family start with `uc-pxx-`.

| Service | Runlevel | State |
|---|---|---|
| `uc-pxx-lvm` | boot | Done. Activates the data volume |
| `uc-pxx-watchdog` | boot | Done. Feeds `/dev/watchdog0` with the busybox watchdog |
| `uc-pxx-firmware` | boot | Copies the Wi-Fi and Bluetooth files from the vendor partition. See "Firmware" |
| `uc-pxx-switch` | boot | Sets the MAC address and starts the Ethernet switch. Not tested in this form |
| `uc-pxx-audio` | default | Done. Mixer defaults and volume |
| `uc-pxx-boot-ok` | default | Starts the boot-marking hook. See [boot-control.md](boot-control.md) |
| `uc-pxx-als` | default | Stub. The light sensor feed is not written |

### Firmware

The AP6256 module needs firmware that belongs to the vendor. The repository
and the images hold none. `uc-pxx-firmware` copies three files from the
vendor partition (mounted read-only) to `/lib/firmware/brcm`:

| Vendor file | Copy |
|---|---|
| `fw_bcm43456c5_ag.bin` | `brcmfmac43456-sdio.bin` |
| `nvram_ap6256_FCC.txt` | `brcmfmac43456-sdio.txt` |
| `BCM4345C5.hcd` | `BCM4345C5.hcd` |

Open points:

- Phase 1 reads them from `vendor_b`. Phase 2 has no vendor partition. The
  installer must save the files to `/data` first.
- The program always copies the FCC NVRAM file. It must choose by region.
- The drivers are built in. They may probe before the files exist. A re-probe
  after the copy is not written yet.

### Switch

The GMAC connects to an RTL8364B switch. `uc-pxx-switch` sets the MAC address
of eth0 and runs `rtl8363-init` while eth0 is down. The tool is built from
`tools/rtl8363-init` and links with the Realtek switch SDK (GPL-2.0).

The tool talks to the kernel driver `realtek-rtl8364b-smi` (compatible
`realtek,rtl8364b-smi`). The driver makes the file `smi` of the MDIO device:

| Item | Path or text |
|---|---|
| Device file | `/sys/bus/mdio_bus/devices/stmmac-0:1d/smi` |
| Driver folder | `/sys/bus/mdio_bus/drivers/realtek-rtl8364b-smi/` |
| `dmesg` prefix | `realtek-rtl8364b-smi stmmac-0:1d` |

The device file does not depend on the driver name. The service and the tool
look in the driver folder (`*/smi`).

### Audio

`uc-pxx-audio` replaces `tsx-audio` of the xx70. `uc-pxx-audio init` sets the
mixer to the state of the stock firmware. `uc-pxx-audio volume N` sets the
speaker level in percent. The configuration is `/etc/tsx/audio.conf`. The
file `/etc/asound.conf` maps the default PCM devices ([hardware.md](hardware.md)).

### Watchdog

`uc-pxx-watchdog` runs the busybox watchdog on `/dev/watchdog0`. The service
reads the maximum timeout from sysfs and lowers a larger setting to it. The
settings are in `/etc/conf.d/uc-pxx-watchdog`.

### Keys

`/etc/tsx/buttons-board.conf` lists the six touch keys in their physical
order: `teams`, `headset`, `speaker`, `volume_down`, `volume_up` and `mic`
([hardware.md](hardware.md) has the table). The layout is verified with
evtest. The four key LEDs are on/off LEDs: the file sets `LED_MODE=onoff`, and
the keys Teams, Headset, Speaker and Mic use `led=1` to `led=4`.

## Tests

The tests run on a host and need no unit. The workflow `tests.yml` runs them.

| Test | Checks |
|---|---|
| `rootfs/tests/test-profiles.sh` | The package, service and image file lists of the profiles |
| `rootfs/tests/test-board.sh` | The board values, the board hook, the MAC address, the model, the key codes and the key LEDs |
| `rootfs/tests/test-audio.sh` | `uc-pxx-audio` with a stub `amixer` |
| `rootfs/tests/test-firmware.sh` | `uc-pxx-firmware` with a made-up vendor folder |
| `rootfs/tests/test-switch.sh` | `uc-pxx-switch` with stub tools |
| `rootfs/tests/test-watchdog.sh` | The timeout checks of `uc-pxx-watchdog` |
| `rootfs/tests/test-kernel-pins.sh` | `rootfs/check-kernel-pins.sh` |

## TODO

- `tsx-hw` and `panel-board.d/default.conf` (backlight and sensor values).
  `tsx-config` warns and goes on without them.
- A data volume check for the first boot (`tsx-data` of common).
- The light sensor feed (`uc-pxx-als`).
- Chromium flags for panfrost (`TSX_BROWSER_GL_FLAGS`).
- The Bluetooth proxy default (`TSX_BT_PROXY_DEFAULT` is `off` until tested).
- The initramfs and the rescue system.
