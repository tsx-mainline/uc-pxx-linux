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

### Hardware facts and panel-board.d

`tsx-hw detect` runs at boot, from the common script of `tsx-config`. It
writes two files in `/run/tsx`:

- `hw.conf`, the facts of the panel. `tsx-config`, `tsx-setupd`, `tsx-bt`,
  `tsx-voice` and the ESPHome device read it.
- `panel-board.conf`, the board values. `/etc/tsx/panel-board.conf` is a link
  to it. The program builds it from `/etc/tsx/panel-board.d/default.conf`, then
  `UC-P10.conf` or `UC-P8.conf` (the model of the device tree), then
  `local.conf`. A key in a later file replaces the key of an earlier file.

| Key | Value | Source |
|---|---|---|
| `ORIENTATION_HW` | `landscape` | Fixed. The UC-P10 is a landscape device |
| `MIC`, `BT`, `WIFI` | `yes` | Fixed. Parts of the board |
| `CAMERA` | `no` | Fixed. The camera is not fitted |
| `LEDBAR` | `no` | Fixed. The USB-C port is a device port, so no LED bar can be attached |
| `PRESENCE` | `yes` or `no` | An input device `gpio-keys` with the switch bit 11 (`SW_FRONT_PROXIMITY`) |
| `LIGHT` | `yes` or `no` | An IIO device named `jsa1212` |

`default.conf` holds the backlight range and the values of the light sensor.
The backlight has five PWM levels in the device tree, so the device has the
steps 0 to 4. `BACKLIGHT_MAX=4` and `BACKLIGHT_MIN=1` follow from that.
Nobody has tuned these values on the glass.

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
| `uc-pxx-status-led` | default | Done. Blue heartbeat on the status LED until slot A is marked good, then solid green. See "Status LED" |
| `uc-pxx-als` | default | Done. Reads the light sensor and feeds the automatic brightness. See "Ambient light" |

### Status LED

`uc-pxx-status-led` shows the boot state on the RGB status LED. It uses the
LED class devices `green` and `blue` of `/sys/class/leds`.

| State of slot A | Status LED |
|---|---|
| Not marked successful (the boot is new or an update armed it) | Blue, trigger `heartbeat` |
| Marked successful | Green on, blue off |

The program reads the state with `uc-pxx-bootctl status` every 10 seconds. The
command only reads the A/B sector. It writes one line to the kernel log each
time. The program stops when slot A is successful, or after 10 minutes. If
slot A is still not successful then, blue keeps the heartbeat.

The program never writes the `red` LED. `uc-pxx-arm-slot` and the
boot-marking hook light red when the A/B state is unknown
([boot-control.md](boot-control.md)). Nothing in the program clears it.

After `uc-pxx-arm-slot` armed slot A in a running system, the LED stays as it
is until the next boot. The next boot starts the program again.

### Ambient light

`uc-pxx-als` reads the JSA1213 through the mainline driver `jsa1212`. The
driver shows the sensor as the IIO device `jsa1212` with `in_illuminance_raw`
(counts, 0 to about 4000) and `in_illuminance_scale` (0.5).

The program turns the counts into lux: `lux = counts x in_illuminance_scale x
ALS_SCALE`. The range is 0 to about 2000 lux in steps of 0.5 lux. The unit
that we tested read 58 counts (29 lux) in a room, 1 count (0.5 lux) when
covered and 138 counts (69 lux) with a flashlight.

`ALS_SCALE` corrects for the front window. It is 1 in `panel-board.d/default.conf`
because nobody has measured the window. Measure a known light and set the
factor in `panel.conf` (`ALS_SCALE`) or in `local.conf`. The curve of the
automatic brightness has its top at `AUTO_BRIGHTNESS_LUX` (500 lux). It goes
from `BRIGHTNESS_NIGHT` to `BRIGHTNESS_DAY` on a log scale. Both values are
steps of the backlight, which has the steps 1 to 4.

The program writes the shared files of tsx-linux-common:

| File | Content | Read by |
|---|---|---|
| `/run/tsx/als.state` | `raw` (lux), `report` (lux with a deadband), `auto`, `scale`, `learned`, `counts` | `tsx-panelctl`, `tsx-mqtt`, `tsx_panel`, the overlay |
| `/run/tsx/als-level` | The backlight level, while `AUTO_BRIGHTNESS` is on | `tsx-idled` |

`AUTO_BRIGHTNESS` is on while `panel.conf` does not set it. `tsx-als auto
on|off` (the Home Assistant switch and the overlay call it) sets it and runs
`tsx-config apply`. The apply reloads `uc-pxx-als` (`TSX_CONFIG_RELOAD`).
`ALS_WATCH=1` in `default.conf` makes `tsx-idled` apply a new level at once.

The shared module `tsx_brightness.py` (package `tsx-base`) gives the
debounce of the light and the learning of the curve. Without it, the level
follows the light with no debounce.

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
| `rootfs/tests/test-hw.sh` | `tsx-hw` with a made-up `/sys`: the facts and the layers of `panel-board.d` |
| `rootfs/tests/test-als.sh` | `uc-pxx-als` and `tsx-als` with a made-up IIO device: counts to lux, the files, the backlight range, a reload |
| `rootfs/tests/test-audio.sh` | `uc-pxx-audio` with a stub `amixer` |
| `rootfs/tests/test-firmware.sh` | `uc-pxx-firmware` with a made-up vendor folder |
| `rootfs/tests/test-status-led.sh` | `uc-pxx-status-led` with fake LEDs and a stub for `uc-pxx-bootctl` |
| `rootfs/tests/test-switch.sh` | `uc-pxx-switch` with stub tools |
| `rootfs/tests/test-watchdog.sh` | The timeout checks of `uc-pxx-watchdog` |
| `rootfs/tests/test-kernel-pins.sh` | `rootfs/check-kernel-pins.sh` |

## TODO

- Tune the backlight steps and `ALS_SCALE` in `panel-board.d/default.conf` on
  the glass.
- A data volume check for the first boot (`tsx-data` of common).
- Chromium flags for panfrost (`TSX_BROWSER_GL_FLAGS`).
- The Bluetooth proxy default (`TSX_BT_PROXY_DEFAULT` is `off` until tested).
- The initramfs and the rescue system.
