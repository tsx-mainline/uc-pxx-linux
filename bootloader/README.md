# Shim

The UC-P10 has no bootloader of our own. The vendor U-Boot starts the kernel
of the boot image and gives it no device tree. The file `shim.S` is the small
program that fills this gap. It is our own code under GPL-2.0-or-later.

## What it does

The shim is the "kernel" of the Android boot image. It is a valid arm64
Image, and it has three parts:

| Offset | Content |
|---|---|
| 0 | The stub (code and a few messages) |
| 64 KiB | The device tree |
| 2 MiB | The Linux Image |

At start the stub prints a few lines on UART2, copies the Linux Image to its
final address and jumps to it. Register `x0` holds the address of the device
tree. The boot chain is in [../docs/boot.md](../docs/boot.md).

## Build

`kernel/mkimage.sh` assembles and links the shim and makes the boot image.
Do not build the shim by hand. The script sets the sizes and the addresses
(`IMAGE_SIZE`, `LINUX_FILE_SIZE`, `LINUX_DEST`, `DTB_FILE` and `LINUX_IMAGE`)
and checks that the copy does not overlap its source.

## Display option

The source has a block for a simple-framebuffer boot. It sets up the VOP
window and the pixel clock. The block is off, because `FB_BASE` is not
defined. The kernel driver rockchip-drm sets up the display itself.
