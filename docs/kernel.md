# Kernel

The UC-P10 runs a mainline kernel with a small set of carried commits. This
page tells the plan for the kernel branch, how to build it and how to make
the boot image.

## Branch and pin

| Flavor | Branch | Base tag |
|---|---|---|
| LTS (default) | `uc-pxx-lts` | `v6.18.54` |

`kernel/KERNEL_REV.lts` pins one revision. It is a placeholder today, because
the branch does not exist yet. `ci/build-kernel.sh` stops with an error while
the pin is the placeholder.

A stable flavor (`uc-pxx-stable`, v7.2) comes later. Develop on stable first
and carry the change to LTS, as the sister projects do.

## What the branch holds

The bring-up kernel is the TSW-770 branch of tsx-xx70-linux with one patch for
the UC-P10. The patch has these parts:

| Part | Content |
|---|---|
| Display | Board device tree base, the Himax panel driver (`panel-himax-ucp10.c`) |
| Network | GMAC fixed link, the RTL8364B management driver (`ucp10-rtl8364b-smi.c`), fusb302 and USB-C role switch |
| Hardware | PMIC and rails, CPU and GPU frequency tables, thermal, io-domains, touch with the six keys, Wi-Fi, Bluetooth, audio, LEDs, keys, SARADC, light sensor |
| Audio | TAS5825M codec driver and a refcount fix in audio-graph-card2 |
| OP-TEE | A probe change that accepts the old ABI revision. The device tree disables the node |

The `uc-pxx-lts` branch starts from a clean `v6.18.54` instead. It carries
only the UC-P10 commits and drops the commits of the TSW-770 that the
UC-P10 does not need. Another task makes this branch.

Names:

- The device tree is `arch/arm64/boot/dts/rockchip/rk3399-crestron-ucp10.dts`
  with the compatible `crestron,uc-p10`.
- The config fragment is `arch/arm64/configs/uc-pxx.config`.
- The kernel worktrees are `linux-uc-pxx-6.18` and `linux-uc-pxx-7.2`.

## Everything is built in

The board needs no kernel module to boot. The drivers for the display,
network, Wi-Fi, Bluetooth, audio, touch and GPU are built in. The initramfs is
built into the Image (`CONFIG_INITRAMFS_SOURCE`). The firmware for Wi-Fi and
Bluetooth is not in the initramfs. The service `uc-pxx-firmware` copies it
from the unit. See rootfs.md.

## Build

Build on a build host and never on the workstation.

1. Run `ci/build-kernel.sh --flavor lts --initramfs FILE`. `FILE` is the cpio
   archive for the built-in initramfs.
2. The script writes `Image`, `rk3399-crestron-ucp10.dtb`, `kernel.release`,
   `kernel.commit` and `sha256sums.txt` to the output folder.
3. Run `kernel/mkimage.sh` with the Image, the device tree, a resource for
   U-Boot and a build token. It writes the boot image.

The initramfs is open (see the status table in the [README](../README.md)).

## Boot image

`kernel/mkimage.sh` ports the shim build of the bring-up tree. It needs the
resource for U-Boot as an argument, because that file derives from vendor
files. [boot.md](boot.md) tells what the boot image holds and which size
limits apply. The tests are `kernel/tests/test-mkimage.sh` and
`kernel/tests/test-mkresource.sh`.

A rebuilt kernel is not bit-for-bit the same. The build time, the host and
the `-dirty` suffix are in the Image. Check a rebuilt image by these points:

- The device tree in the shim equals the built device tree.
- The initramfs checksum equals the expected one.
- The resource checksum equals the expected one.
- `kernel/mkimage.sh` prints "linux payload verified".

## TODO

- Create the branch and fill in `kernel/KERNEL_REV.lts`.
- Add the stable flavor.
- Add the UC-P8 device tree and panel driver.
