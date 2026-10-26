# uc-pxx-linux

Mainline Linux for the Crestron UC-P room phones, in place of the vendor
Android firmware. The first model is the UC-P10. The UC-P8 comes later.

The UC-P10 is a Rockchip RK3399 board (arm64) with a MIPI-DSI touch screen,
an Atmel touch controller with six touch keys, an AIC3104 audio codec, an
AP6256 Wi-Fi and Bluetooth module, and an RTL8364B Ethernet switch. This
project boots a current mainline kernel on it. It is the sister project of
tsx-xx70-linux and tsx-xx60-linux. It follows their layout and uses the
shared software of tsx-linux-common.

The family name is `uc-pxx`. The repository, the packages, the tools and the
services of this family use the prefix `uc-pxx`. The software from
tsx-linux-common keeps its `tsx-` names.

## Status

This repository holds the board files, the boot-control tools, the
initramfs, the kernel pin and the image build of the family. The apk
repository tsx-aports builds the packages of the family (category `uc-pxx`)
from the board tags of this repository, see [rootfs.md](docs/rootfs.md)
"Where the packages come from". One UC-P10 runs these packages from a local
build of the tsx-aports recipes. Its updates, also of the kernel, run through
`tsx-autoupdate`. The table shows what is done and what is open.

| Area | Status |
|---|---|
| Layout, CI checks, docs | Done |
| Boot image build (`kernel/mkimage.sh`, shim) | Done. The kernel package of tsx-aports uses it. The unit boots its images |
| Kernel branch `uc-pxx-lts` | Done. `kernel/KERNEL_REV.lts` pins `d02e92631f28`. The unit runs a build of the same source tree |
| Root file system build (`rootfs/`) | Ported from tsx-xx70-linux. A build of the `ha` profile from test packages ran on a build host |
| Board files (`board.sh`, audio, buttons, fstab, inittab) | In the package `uc-pxx-board`. They run on one UC-P10. Open points are in [rootfs.md](docs/rootfs.md) "TODO" |
| Services `uc-pxx-audio`, `uc-pxx-watchdog` | Ported, with host tests. In the package `uc-pxx-board` |
| Services `uc-pxx-firmware`, `uc-pxx-switch`, `uc-pxx-als` | Written, with host tests. The open points are TODO markers in each file |
| A/B boot control, flash wrapper and arm helper | Reviewed. The packages pin the exact files, see [boot-control.md](docs/boot-control.md) |
| LED package `uc-pxx-leds` (daemon, command, ESPHome plugin) | Written. Tested with fake LEDs, see [leds.md](docs/leds.md). Installed on one UC-P10 |
| ESPHome board plugin (switches) | Written. Tested with a real `EVIOCGSW`. Not run on a unit |
| Initramfs and rescue | Written (`rootfs/initramfs`): boot splash, rescue screen, login of the panel, install of `system_a`. See [boot.md](docs/boot.md) |
| Installer | Open, see [install.md](docs/install.md) |

The bring-up kernel ran on one UC-P10 from slot A. It showed the display,
Ethernet through the switch, all six CPU cores with frequency scaling, Wi-Fi,
Bluetooth, touch with the six keys, audio on the AIC3104, the GPU with
panfrost, the light sensor, the LEDs and the switches. See
[hardware.md](docs/hardware.md).

## Supported models

- **UC-P10**: the first target. Panel 1200x1920, rotated 270 degrees.
- **UC-P8**: not tested. It shares the stock firmware and the device tree
  with the UC-P10. It has a different panel (800x1280) and needs its own
  panel driver and device tree.

## Repository layout

```
bootloader/          the shim source (the boot image kernel stub)
ci/                  lint and repository checks
COMMON_REF           the tsx-linux-common tag of the CI tests
docs/                family, boot chain, hardware, kernel, rootfs, boot control, install
kernel/              kernel revision pin, kernel build, boot image assembly
packages/            self-contained packages (uc-pxx-leds)
rootfs/              root file system builder, profiles, board overlay, tests
tools/               helpers for the board (switch init)
.github/workflows/   CI workflows
```

## Documentation

- [boot.md](docs/boot.md): the boot chain, the shim and the slot layout
- [hardware.md](docs/hardware.md): the board and its parts
- [kernel.md](docs/kernel.md): kernel branch, build and boot image
- [rootfs.md](docs/rootfs.md): the root file system, profiles, board files and services
- [boot-control.md](docs/boot-control.md): the A/B boot control, the pinned files and the kernel updates
- [leds.md](docs/leds.md): the LED package
- [install.md](docs/install.md): the plan of the install path (no installer in this repository yet)

## Warning

The UC-P10 has secure boot fused on. There is no software recovery from a
state with zero bootable slots. Never write the A/B metadata, the idbloader,
the partition table or the only bootable slot without a verified backup, a
verified image and a second bootable slot. Read [boot.md](docs/boot.md) and
[boot-control.md](docs/boot-control.md) first.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE). Third-party code keeps its own
license. No Crestron files are part of this repository. The firmware comes
from each unit.

## Trademark notice

Crestron is a trademark of Crestron Electronics, Inc. This project is not
affiliated with or endorsed by Crestron.
