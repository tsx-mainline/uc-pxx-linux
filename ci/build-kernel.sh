#!/bin/bash
# Build the kernel of the UC-P10 on a plain x86 Linux host, with the aarch64
# cross compiler. It needs no docker and no hardware.
#
#   ci/build-kernel.sh --flavor lts [--src DIR] [--out DIR] [--jobs N] [--initramfs FILE]
#
# The script reads the pinned revision from kernel/KERNEL_REV.<flavor>. It
# gets that revision from KERNEL_REPO (default
# https://github.com/tsx-mainline/linux) when --src has no checkout of it.
# It builds in <src>/../build-<flavor> and writes these files to --out
# (default <src>/../out-<flavor>):
#   Image (not compressed, with the initramfs built in), the device tree
#   rk3399-crestron-ucp10.dtb, kernel.release, kernel.commit,
#   modules-<release>.tar.gz (only when the kernel has modules), sha256sums.txt
# kernel/mkimage.sh makes the boot image from Image and the device tree.
#
# --initramfs FILE sets CONFIG_INITRAMFS_SOURCE to the cpio archive FILE.
# Without it, the Image has whatever initramfs the config names.
#
# Host packages: gcc-aarch64-linux-gnu, make, bc, bison, flex, libssl-dev,
# libelf-dev, kmod, zstd, git.
# Env: CROSS_COMPILE (default aarch64-linux-gnu-), KERNEL_REPO, DTB_NAMES (the
# device trees to build, separated by spaces).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
FLAVOR= SRC= OUT= INITRAMFS= JOBS=$(nproc)
usage() { sed -n '2,24p' "$0" >&2; exit 2; }
while [ $# -gt 0 ]; do
	case $1 in
	--flavor) FLAVOR=${2:?}; shift;;
	--src) SRC=${2:?}; shift;;
	--out) OUT=${2:?}; shift;;
	--jobs) JOBS=${2:?}; shift;;
	--initramfs) INITRAMFS=${2:?}; shift;;
	-h|--help) usage;;
	*) usage;;
	esac
	shift
done
case $FLAVOR in lts) ;; *) usage;; esac
REPO_URL=${KERNEL_REPO:-https://github.com/tsx-mainline/linux}
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
DTBS=${DTB_NAMES:-rk3399-crestron-ucp10.dtb}
REV=$(grep -v '^#' "$HERE/kernel/KERNEL_REV.$FLAVOR" | head -n 1 | tr -d ' \n')
[ ${#REV} = 40 ] || { echo "build-kernel: kernel/KERNEL_REV.$FLAVOR has no 40 digit revision" >&2; exit 1; }
case $REV in *[!0]*) ;; *) echo "build-kernel: kernel/KERNEL_REV.$FLAVOR is still the placeholder" >&2; exit 1;; esac
SRC=${SRC:-$HERE/../linux-uc-pxx-$FLAVOR}
BUILD=$(dirname "$SRC")/build-$FLAVOR
OUT=${OUT:-$(dirname "$SRC")/out-$FLAVOR}
command -v "${CROSS}gcc" >/dev/null || { echo "build-kernel: no ${CROSS}gcc" >&2; exit 1; }
[ -z "$INITRAMFS" ] || [ -f "$INITRAMFS" ] || { echo "build-kernel: no initramfs $INITRAMFS" >&2; exit 1; }

echo "== source: $REPO_URL $REV -> $SRC"
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$REV" ]; then
	[ -d "$SRC/.git" ] || { mkdir -p "$SRC"; git -C "$SRC" init -q; git -C "$SRC" remote add origin "$REPO_URL"; }
	# A blobless fetch keeps the history and the tags. So "make kernelrelease"
	# can name the build like the packages expect, and the fetch loads only
	# the files of the checkout.
	git -C "$SRC" fetch -q --filter=blob:none --tags origin "$REV"
	git -C "$SRC" checkout -q --force "$REV"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$REV" ] || { echo "build-kernel: checkout is not at $REV" >&2; exit 1; }

echo "== configure: defconfig + uc-pxx.config"
rm -rf "$BUILD"; mkdir -p "$BUILD"
# A fixed build user and host, as the sister projects use: the kernel version
# string names no build machine.
M="make -C $SRC O=$BUILD ARCH=arm64 CROSS_COMPILE=$CROSS KBUILD_BUILD_USER=build KBUILD_BUILD_HOST=uc-pxx-build"
$M -s defconfig uc-pxx.config
if [ -n "$INITRAMFS" ]; then
	INITRAMFS=$(readlink -f "$INITRAMFS")
	"$SRC/scripts/config" --file "$BUILD/.config" --set-str INITRAMFS_SOURCE "$INITRAMFS"
fi
$M -s olddefconfig

echo "== build: Image, $DTBS"
# shellcheck disable=SC2046 # one word per device tree
$M -j"$JOBS" Image $(for d in $DTBS; do echo "rockchip/$d"; done)
MODULES=no
if grep -q '^CONFIG_MODULES=y' "$BUILD/.config"; then
	MODULES=yes
	$M -j"$JOBS" modules
fi
KREL=$(cat "$BUILD/include/config/kernel.release")
echo "kernel release: $KREL"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
if [ "$MODULES" = yes ]; then
	echo "== modules_install (stripped)"
	$M -s INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$W/mods" modules_install
	rm -f "$W/mods/lib/modules/$KREL/build" "$W/mods/lib/modules/$KREL/source"
	[ -f "$W/mods/lib/modules/$KREL/modules.dep" ] || { echo "build-kernel: no modules.dep for $KREL" >&2; exit 1; }
fi

echo "== output: $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)  # a relative --out works after the cd below
cp "$BUILD/arch/arm64/boot/Image" "$OUT/Image"
for d in $DTBS; do cp "$BUILD/arch/arm64/boot/dts/rockchip/$d" "$OUT/$d"; done
echo "$KREL" > "$OUT/kernel.release"
echo "$REV" > "$OUT/kernel.commit"
FILES="Image $DTBS kernel.release kernel.commit"
if [ "$MODULES" = yes ]; then
	(cd "$W/mods" && tar --owner=0 --group=0 --numeric-owner -czf "$OUT/modules-$KREL.tar.gz" lib)
	FILES="$FILES modules-$KREL.tar.gz"
fi
# shellcheck disable=SC2086 # one word per file
(cd "$OUT" && sha256sum $FILES > sha256sums.txt)
cat "$OUT/sha256sums.txt"
