#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Assemble the Android boot image (header version 0) for a boot_a or boot_b
# partition of the UC-P10:
#   kernel   the shim: stub (bootloader/shim.S), device tree and Linux Image
#   ramdisk  a dummy file of 20 bytes (the initramfs is built into the Image)
#   second   the Rockchip resource for U-Boot (--resource)
#   board    the build token (--board)
# docs/boot.md "The boot image" tells why.
#
# Usage:
#   kernel/mkimage.sh --resource RES.img --board TOKEN [--dest ADDR] IMAGE DTB OUT
#
#   IMAGE      the Linux Image, with the initramfs built in (ci/build-kernel.sh)
#   DTB        the device tree of the board. It holds /chosen/bootargs and no
#              initrd properties
#   OUT        the boot image to write
#   --resource a Rockchip resource (RSCE) with the device tree for U-Boot. The
#              file derives from vendor files and is not part of this
#              repository. kernel/mkresource.py packs one from a device tree
#   --board    the build token, up to 15 characters. The initramfs in the Image
#              has the same string in /etc/uc-pxx-build-id. The boot-marking
#              hook compares them (docs/boot-control.md)
#   --dest     where the stub copies the Linux Image (default 0x4000000, 2 MiB
#              aligned)
#
# Tools: aarch64-linux-gnu-gcc, -ld and -objcopy (CROSS_COMPILE changes the
# prefix), mkbootimg (ci/install-mkbootimg.sh), fdtget (device-tree-compiler),
# gzip, od, cmp, sha256sum. The script makes no file except OUT.
#
# This script does not flash anything. Never write the result to a partition
# without the steps of docs/boot.md and docs/boot-control.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
usage() { sed -n '11,25p' "$0" >&2; exit 2; }

RES= BOARD= DEST=0x4000000
while [ $# -gt 0 ]; do
	case $1 in
	--resource) RES=${2:?}; shift;;
	--board) BOARD=${2:?}; shift;;
	--dest) DEST=${2:?}; shift;;
	-h|--help) usage;;
	-*) usage;;
	*) break;;
	esac
	shift
done
[ $# = 3 ] || usage
LINUX=$1 DTB=$2 OUT=$3
[ -n "$RES" ] && [ -n "$BOARD" ] || usage
for f in "$LINUX" "$DTB" "$RES"; do
	[ -f "$f" ] || { echo "mkimage: no file $f" >&2; exit 1; }
done
for t in "${CROSS}gcc" "${CROSS}ld" "${CROSS}objcopy" mkbootimg fdtget gzip od cmp; do
	command -v "$t" >/dev/null || { echo "mkimage: $t is not installed" >&2; exit 1; }
done
[ ${#BOARD} -le 15 ] || { echo "mkimage: --board is longer than 15 characters" >&2; exit 1; }

PAGE=2048
# vbmeta limits the size of the boot image. A larger image is truncated and
# fails the check at boot (docs/boot.md "Size limits").
MAX_IMAGE=${UC_PXX_MAX_IMAGE:-67108864}
# The secure OS starts here. The Linux Image must end below it.
SECURE_OS=0x8400000
STUB_SIZE=0x200000

LFS=$(stat -c %s "$LINUX")
LIS=$(od -An -tu8 -j16 -N8 "$LINUX" | tr -d ' ')
[ "$LIS" -gt 0 ] || { echo "mkimage: $LINUX has no image_size in its arm64 header" >&2; exit 1; }
[ $((DEST % 0x200000)) = 0 ] || { echo "mkimage: --dest $DEST is not 2 MiB aligned" >&2; exit 1; }
[ $((DEST + LIS)) -lt $((SECURE_OS)) ] || { echo "mkimage: the Linux Image at $DEST overlaps the secure OS" >&2; exit 1; }
# A boot from the partition runs the stub at 0x280000 (kernel_addr_r). A boot
# from RAM runs it at 0xa200800. The copy goes forward. So the source must end
# before the destination starts, or start after the destination ends.
[ $((0x280000 + STUB_SIZE + LFS)) -le $((DEST)) ] || { echo "mkimage: the copy overlaps its source on a boot from the partition" >&2; exit 1; }
[ $((0xa200800 + STUB_SIZE)) -ge $((DEST + LIS)) ] || { echo "mkimage: the copy overlaps its source on a boot from RAM" >&2; exit 1; }

# The kernel gets its command line from the device tree.
[ -n "$(fdtget "$DTB" /chosen bootargs 2>/dev/null || true)" ] ||
	{ echo "mkimage: $DTB has no /chosen/bootargs: the kernel would have no command line" >&2; exit 1; }
# The initramfs is built into the Image. A leftover initrd property would
# make the kernel look for a second one.
! fdtget "$DTB" /chosen linux,initrd-start >/dev/null 2>&1 ||
	{ echo "mkimage: $DTB still has initrd properties" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gzip -9n < /dev/null > "$tmp/ramdisk.gz"

"${CROSS}gcc" -c -DIMAGE_SIZE=$((STUB_SIZE + LIS)) -DLINUX_FILE_SIZE="$LFS" -DLINUX_DEST="$DEST" \
	-DDTB_FILE="\"$DTB\"" -DLINUX_IMAGE="\"$LINUX\"" -o "$tmp/shim.o" "$HERE/bootloader/shim.S"
"${CROSS}ld" -Ttext=0 -o "$tmp/shim.elf" "$tmp/shim.o"
"${CROSS}objcopy" -O binary "$tmp/shim.elf" "$tmp/shim.bin"
[ "$(stat -c %s "$tmp/shim.bin")" -eq $((STUB_SIZE + LFS)) ] ||
	{ echo "mkimage: the shim has the wrong size" >&2; exit 1; }

# The command line in the header is not used. The kernel reads the device tree.
CMDLINE="console=ttyS2,115200n8 rdinit=/init"
mkbootimg --header_version 0 --pagesize $PAGE --board "$BOARD" --kernel "$tmp/shim.bin" \
	--ramdisk "$tmp/ramdisk.gz" --second "$RES" --cmdline "$CMDLINE" -o "$tmp/boot.img"

# The Linux Image must be in the file at the place where the stub looks.
cmp <(tail -c +$((PAGE + STUB_SIZE + 1)) "$tmp/boot.img" | head -c "$LFS") "$LINUX" ||
	{ echo "mkimage: the Linux Image in the boot image differs from the input" >&2; exit 1; }
echo "linux payload verified"
SZ=$(stat -c %s "$tmp/boot.img")
echo "image $SZ bytes, limit $MAX_IMAGE, headroom $((MAX_IMAGE - SZ))"
[ "$SZ" -le "$MAX_IMAGE" ] || { echo "mkimage: the image is larger than the limit" >&2; exit 1; }
cp "$tmp/boot.img" "$OUT"
sha256sum "$OUT"
