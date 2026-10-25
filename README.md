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

This repository is a skeleton. The layout and the parts that are known from
the bring-up work are here. The kernel, the initramfs, the boot-control
tools and the installer are not here yet. The table shows what is done and
what is open.

| Area | Status |
|---|---|
| Layout, CI checks, docs | Done |
| Boot image build (`kernel/mkimage.sh`, shim) | Ported from the bring-up tree. Not run from this repository yet |
| Kernel branch `uc-pxx-lts` | Done. `kernel/KERNEL_REV.lts` pins `e28b89c4a681`. The kernel builds. Not booted from this repository |
| Root file system build (`rootfs/`) | Ported from tsx-xx70-linux. Not run yet. The apk category `uc-pxx` does not exist yet |
| Board files (`board.sh`, audio, buttons, fstab, inittab) | Written from the bring-up measurements. Not tested on a unit from this repository |
| Services `uc-pxx-audio`, `uc-pxx-watchdog` | Ported. Not tested on a unit from this repository |
| Services `uc-pxx-firmware`, `uc-pxx-switch`, `uc-pxx-als` | Stubs with TODO markers |
| A/B boot control, flash wrapper and arm helper | Renamed from the reviewed bring-up tools. Needs a review of the exact files, see [boot-control.md](docs/boot-control.md) |
| LED package `uc-pxx-leds` (daemon, command, ESPHome plugin) | Written. Tested with fake LEDs, see [leds.md](docs/leds.md). Not run on a unit |
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
docs/                family, boot chain, hardware, kernel, rootfs, boot control, install
kernel/              kernel revision pin, kernel build, boot image assembly
packages/            self-contained packages (uc-pxx-leds)
rootfs/              root file system builder, profiles, board overlay, tests
tools/               helpers for the board (switch init)
.github/workflows/   CI workflows (this repository is local only for now)
```

## Documentation

- [boot.md](docs/boot.md): the boot chain, the shim and the slot layout
- [hardware.md](docs/hardware.md): the board and its parts
- [kernel.md](docs/kernel.md): kernel branch, build and boot image
- [rootfs.md](docs/rootfs.md): the root file system, profiles, board files and services
- [boot-control.md](docs/boot-control.md): the A/B boot control (placeholder)
- [install.md](docs/install.md): the install path (placeholder)

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
