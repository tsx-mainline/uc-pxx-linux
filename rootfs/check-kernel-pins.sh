#!/bin/sh
# Check the kernel package inside a rootfs against the kernel pin.
#
#   check-kernel-pins.sh ROOT [PIN_DIR]
#
# ROOT is the rootfs tree. PIN_DIR holds KERNEL_REV.lts (default: ../kernel
# next to this script). The script reads the kernel release in
# ROOT/boot/uc-pxx-lts.img, the boot image of the kernel package. The release
# must end with -g<first 12 digits of the pinned revision>. The release in
# ROOT/usr/share/uc-pxx/kernel-lts.release must be the same release. If
# ROOT/lib/modules has module trees, one of them must have this release.
# A missing image, a stale image or a different release stops the build with
# exit status 1.
#
# This stops an image that would boot a kernel without the pinned fixes.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${1:?"usage: check-kernel-pins.sh ROOT [PIN_DIR]"}
PINS=${2:-$HERE/../kernel}
fail=0
bad() { echo "check-kernel-pins: $*" >&2; fail=1; }

# The release string of the kernel in a boot image. The Linux Image is in the
# image as it is, so the version banner is plain text.
image_release() {
	grep -a -o -m1 'Linux version [^ ]*' "$1" | head -n 1 | sed 's/^Linux version //' || true
}

for fl in lts; do
	pin=$PINS/KERNEL_REV.$fl
	[ -f "$pin" ] || { bad "no $pin"; continue; }
	rev=$(grep -v '^#' "$pin" | head -n 1 | tr -d ' \n')
	[ ${#rev} = 40 ] || { bad "$pin has no 40 digit revision"; continue; }
	img=$ROOT/boot/uc-pxx-$fl.img
	[ -f "$img" ] || { bad "$fl: no /boot/uc-pxx-$fl.img in the rootfs"; continue; }
	rel=$(image_release "$img")
	[ -n "$rel" ] || { bad "$fl: no kernel release found in /boot/uc-pxx-$fl.img"; continue; }
	short=$(printf '%s' "$rev" | cut -c1-12)
	case $rel in
	*-g"$short") ;;
	*) bad "$fl: the boot image has kernel $rel, the pin is $rev (rebuild the uc-pxx-kernel-$fl package)"; continue;;
	esac
	rf=$ROOT/usr/share/uc-pxx/kernel-$fl.release
	if [ ! -f "$rf" ] || [ "$(cat "$rf")" != "$rel" ]; then
		bad "$fl: kernel-$fl.release is '$(cat "$rf" 2>/dev/null)', the boot image has $rel"
		continue
	fi
	# The board needs no module to boot, so a rootfs may have no module tree.
	if [ -n "$(ls "$ROOT/lib/modules" 2>/dev/null)" ] && [ ! -d "$ROOT/lib/modules/$rel" ]; then
		bad "$fl: /lib/modules has no tree for $rel"
		continue
	fi
	echo "check-kernel-pins: $fl $rel matches $short"
done
exit $fail
