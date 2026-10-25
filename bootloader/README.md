# Shim

The UC-P10 has no bootloader of our own. The vendor U-Boot starts the kernel
of the boot image where it loaded it. It passes its own device tree (on a
boot from a slot) or none (on a `fastboot boot`). The file `shim.S` is the
small program that fills this gap. It is our own code under
GPL-2.0-or-later.

## What it does

The shim is the "kernel" of the Android boot image. It is a valid arm64
Image, and it has three parts:

| Offset | Content |
|---|---|
| 0 | The stub (code and a few messages) |
| 64 KiB | The device tree |
| 2 MiB | The Linux Image |

At start the stub prints a few lines on UART2 and copies the Linux Image to
its final address. Then it copies `/chosen/bootargs` of the U-Boot device
tree into the new property `/chosen/u-boot,bootargs` of our device tree, if
U-Boot passed one. The line `u-boot args 0x...` on UART2 shows the result
(0 copied, 1 no device tree from U-Boot, 2 no `bootargs` in it, 3 our device
tree is not usable, 4 no room or too long, 5 already there). Then the stub
jumps to Linux. Register `x0` holds the address of our device tree. The boot
chain is in [../docs/boot.md](../docs/boot.md).

`kernel/tests/test-shim-fdt.sh` tests the device tree code under
qemu-aarch64. It assembles only that part of `shim.S`
(`UC_PXX_SHIM_FDT_TEST`).

## Build

`kernel/mkimage.sh` assembles and links the shim and makes the boot image.
Do not build the shim by hand. The script sets the sizes and the addresses
(`IMAGE_SIZE`, `LINUX_FILE_SIZE`, `LINUX_DEST`, `DTB_FILE` and `LINUX_IMAGE`)
and checks that the copy does not overlap its source.

## Display option

The source has a block for a simple-framebuffer boot. It sets up the VOP
window and the pixel clock. The block is off, because `FB_BASE` is not
defined. The kernel driver rockchip-drm sets up the display itself.
