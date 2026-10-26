# Kernel

The UC-P10 runs a mainline kernel with a small set of carried commits. This
page tells the plan for the kernel branch, how to build it and how to make
the boot image.

## Branch and pin

| Flavor | Branch | Base tag |
|---|---|---|
| LTS (default) | `uc-pxx-lts` | `v6.18.54` |

`kernel/KERNEL_REV.lts` pins one revision of the branch: the 40 digit commit
`d02e92631f2810a4a43fb6f09824afb9b0044ee2`. `ci/build-kernel.sh` fetches that
commit and stops if the checkout differs from it.

A stable flavor (`uc-pxx-stable`, v7.2) comes later. Develop on stable first
and carry the change to LTS, as the sister projects do.

## What the branch holds

The branch starts from a clean `v6.18.54` and carries only the commits for
the UC-P10 and the UC-P8. It has one commit of the TSW-770 tree (the vendor
prefix `crestron`). The names of the drivers do not have a model prefix:

| Part | Content |
|---|---|
| Display | The shared board file `rk3399-crestron-uc-pxx.dtsi`, the Himax panel driver `panel-crestron-uc-p10.c` (`DRM_PANEL_CRESTRON_UC_P10`) and the ILI9881C panel of the UC-P8. `fbcon=map:1` keeps the console off the LCD for the boot splash, `vt.global_cursor_default=0` hides its cursor, and the kernel has no boot logo. The device tree reserves the display pool of U-Boot (`0xf5f00000`, 32 MiB), so the U-Boot logo stays intact until `rockchip-drm` binds ([boot.md](boot.md) "The boot image"). The UC-P10 panel runs at 52.96 Hz: the horizontal timing of the stock U-Boot, 148.5 MHz from VPLL 1188 MHz, 992 Mbps per lane as in U-Boot |
| Network | GMAC fixed link, the RTL8364B management driver `realtek-rtl8364b-smi.c` (`REALTEK_RTL8364B_SMI`, compatible `realtek,rtl8364b-smi`), fusb302 and USB-C role switch |
| Hardware | PMIC and rails, CPU and GPU frequency tables, thermal, io-domains, touch with the six keys, Wi-Fi, Bluetooth, audio, LEDs, keys, SARADC, light sensor |
| Audio | TAS5825M codec driver (it probes without its sequence file and without the amplifier, so the AIC3104 path still works) and a refcount fix in audio-graph-card2 |

The UC-P8 device tree and panel are build-only. No UC-P8 unit was available
to test them.

Names:

- The device trees are `arch/arm64/boot/dts/rockchip/rk3399-crestron-ucp10.dts`
  (compatible `crestron,uc-p10`) and `rk3399-crestron-ucp8.dts` (compatible
  `crestron,uc-p8`).
- The config fragment is `arch/arm64/configs/uc-pxx.config`.
- The kernel worktrees are `linux-uc-pxx-6.18` and `linux-uc-pxx-7.2`.

## Everything is built in

The board needs no kernel module to boot. The drivers for the display,
network, Wi-Fi, Bluetooth, audio, touch and GPU are built in. The initramfs is
built into the Image (`CONFIG_INITRAMFS_SOURCE`). The config fragment does not
set the source, so the build gets it as an input. The firmware for Wi-Fi and
Bluetooth is not in the initramfs. The service `uc-pxx-firmware` copies it
from the unit. See [rootfs.md](rootfs.md).

## Build

Build on a build host and never on the workstation.

1. Make the initramfs as an uncompressed cpio archive (newc format).
2. Run `ci/build-kernel.sh --flavor lts --initramfs FILE`. The option is
   required. The script copies `FILE` into the build folder, sets
   `CONFIG_INITRAMFS_SOURCE` to the relative name of the copy and sets
   `CONFIG_INITRAMFS_COMPRESSION_XZ=y`. The kernel compresses the archive.
   The Image holds its config (`CONFIG_IKCONFIG`), so the relative name keeps
   the paths of the build host out of it.
3. The script writes `Image`, `rk3399-crestron-ucp10.dtb`,
   `rk3399-crestron-ucp8.dtb`, `kernel.release`, `kernel.commit` and
   `sha256sums.txt` to the output folder.
4. For each model, run `kernel/mkimage.sh` with the same Image, the device
   tree of that model, a resource for U-Boot and a build token. It writes the
   boot image of that model.

The device tree is in the boot image, so each model needs its own image.
`DTB_NAMES` limits the device trees that the script builds.

`rootfs/build-rootfs.sh initramfs` makes the initramfs
([boot.md](boot.md) "The boot initramfs"). The CI jobs build with a minimal
initramfs, because the real one needs the switch tool, which links with the
Realtek SDK.

## Boot image

`kernel/mkimage.sh` ports the shim build of the bring-up tree. It needs the
resource for U-Boot as an argument, because that file derives from vendor
files. [boot.md](boot.md) tells what the boot image holds and which size
limits apply. The tests are `kernel/tests/test-build-kernel.sh`,
`kernel/tests/test-mkimage.sh` and
`kernel/tests/test-mkresource.sh`.

A rebuilt kernel is not bit-for-bit the same. The build time, the host and
the `-dirty` suffix are in the Image. Check a rebuilt image by these points:

- The device tree in the shim equals the built device tree.
- The initramfs checksum equals the expected one.
- The resource checksum equals the expected one.
- `kernel/mkimage.sh` prints "linux payload verified".

## TODO

- Add the stable flavor.
- Add the UC-P8 device tree and panel driver.
