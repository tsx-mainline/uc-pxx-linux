#!/bin/sh
# Fail if the source tree or a build output has a file that belongs to the
# vendor. The repo and its releases never hold these files. The service
# uc-pxx-firmware copies them from the unit itself at boot:
#   - Wi-Fi and Bluetooth firmware from the vendor partition: the brcmfmac
#     firmware and NVRAM files of the AP6256 and the BCM4345C5 patch file
#   - the TAS5825M register sequence (tas5825m*.bin)
#   - Android images (system, vendor, boot, resource and sparse images) and
#     the firmware packages of the vendor (.pcdfw, .puf)
# The check looks at file names and at the content lists of the build output.
# It does not depend on a build option. So a later change to mkrootfs.sh
# cannot add one of these files without a failure here.
#
#   ci/check-no-proprietary.sh [ROOTFS_OUT]
#
# The script always scans the source tree (the repository that holds it).
# ROOTFS_OUT is a build output directory, for example rootfs/out. The script
# scans the file names in it and the content lists of rootfs.tar.gz and
# rootfs.ext4 when they exist. The ext4 scan mounts the image read-only
# (sudo unless root). UC_PXX_CHECK_SKIP_EXT4=1 skips that scan.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUTDIR=${1:-}
case ${1:-} in -h|--help) sed -n '2,21p' "$0"; exit 0;; esac
[ -z "$OUTDIR" ] || [ -d "$OUTDIR" ] || { echo "check-no-proprietary: $OUTDIR is not a directory" >&2; exit 2; }

# The base name of a vendor file, for any path.
FW='(^|/)brcmfmac43456-sdio[^/]*$|(^|/)BCM4345C5[^/]*\.hcd$|(^|/)tas5825m[^/]*\.bin$'
FW="$FW"'|(^|/)(fw_bcm43456|nvram_ap6256)[^/]*$|\.pcdfw$|\.puf$|\.cnt$'
FW="$FW"'|lib/firmware/brcm/'
# Android images and the sparse or raw file systems made from them
IMG='\.(img|simg|sparse|ext4|ext4\.img)(\.[a-z0-9]+)?$'
FLAG=$(mktemp); trap 'rm -f "$FLAG"' EXIT

# scan_list LABEL PATTERN: read names on stdin and print the ones that match.
# It runs in a pipeline, so it reports a hit through the file $FLAG.
scan_list() {
	label=$1 pat=$2
	hits=$(grep -E -i -- "$pat" || true)
	if [ -n "$hits" ]; then
		echo "FOUND in $label:"; echo "$hits" | sed 's/^/  /' | head -50
		echo 1 > "$FLAG"
	else
		echo "ok: $label"
	fi
}

echo "== source tree $HERE"
# Android images are a source tree problem only. A build output holds ours.
(cd "$HERE" && find . \( -name .git -o -name out -o -name modules \) -prune -o -type f -print) |
	sed 's#^\./##' | scan_list "source tree" "$FW|$IMG"

[ -n "$OUTDIR" ] || { [ ! -s "$FLAG" ] && echo "ok: no vendor files" && exit 0; echo "FAIL: vendor file(s) found (see above)"; exit 1; }

echo "== build output $OUTDIR"
(cd "$OUTDIR" && find . -type f -print) | sed 's#^\./##' | scan_list "file names in $OUTDIR" "$FW"

if [ -f "$OUTDIR/rootfs.tar.gz" ]; then
	echo "== $OUTDIR/rootfs.tar.gz"
	tar tzf "$OUTDIR/rootfs.tar.gz" | scan_list "rootfs.tar.gz" "$FW"
fi

if [ -f "$OUTDIR/rootfs.ext4" ] && [ "${UC_PXX_CHECK_SKIP_EXT4:-0}" != 1 ]; then
	echo "== $OUTDIR/rootfs.ext4"
	SUDO=sudo; [ "$(id -u)" != 0 ] || SUDO=
	MNT=$(mktemp -d)
	$SUDO mount -o loop,ro "$OUTDIR/rootfs.ext4" "$MNT"
	list=$(cd "$MNT" && $SUDO find . -path ./proc -prune -o \( -type f -o -type l \) -print | sed 's#^\./##') || list=
	$SUDO umount "$MNT"; rmdir "$MNT"
	echo "$list" | scan_list "rootfs.ext4" "$FW"
fi

if [ -s "$FLAG" ]; then
	echo "FAIL: vendor file(s) found (see above)"
	exit 1
fi
echo "ok: no vendor files in the source tree or in $OUTDIR"
