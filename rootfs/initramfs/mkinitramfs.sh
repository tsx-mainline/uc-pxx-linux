#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs INSIDE an aarch64 Alpine container (see ../build-rootfs.sh initramfs),
# with the repository at /w. It builds the uc-pxx boot initramfs: /init (the
# switch_root to the root file system of slot A) and the rescue system that
# /init falls back to (docs/boot.md "The boot initramfs").
#
#   mkinitramfs.sh OUT.cpio
#
# OUT is an uncompressed cpio archive (newc). ci/build-kernel.sh --initramfs
# builds it into the kernel Image, and the kernel compresses it.
# Env:
#   ALPINE           Alpine branch (default v3.24)
#   RTL8363_INIT     optional: the static aarch64 rtl8363-init
#                    (tools/rtl8363-init/build.sh). Without it the rescue has
#                    no wired network
#   AUTHORIZED_KEYS  optional, test builds only: ssh public keys that the
#                    rescue dropbear accepts. Without it the rescue has no ssh
#   UIDGID           owner of OUT
# The rescue has no root password. The shell on the serial console needs no
# login.
set -eu
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(apk --print-arch)" = aarch64 ] || { echo "mkinitramfs.sh: this container is $(apk --print-arch), not aarch64"; exit 1; }
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
printf '%s/%s/main\n%s/%s/community\n' "$MIRROR" "${ALPINE:-v3.24}" "$MIRROR" "${ALPINE:-v3.24}" > /etc/apk/repositories
R=/tmp/initramfs; rm -rf $R; mkdir -p $R
# e2fsprogs: e2fsck and dumpe2fs. e2fsprogs-extra: resize2fs.
apk add --root $R --initdb --no-cache -q \
	--repositories-file /etc/apk/repositories --keys-dir /etc/apk/keys \
	alpine-baselayout busybox busybox-binsh dropbear e2fsprogs e2fsprogs-extra
cp -a "$HERE"/overlay/. $R/
chmod 755 $R/init $R/etc/init.d/rcS
if [ -n "${RTL8363_INIT:-}" ]; then
	[ -x "$RTL8363_INIT" ] || { echo "mkinitramfs.sh: RTL8363_INIT=$RTL8363_INIT is not an executable"; exit 1; }
	install -m 755 "$RTL8363_INIT" $R/usr/sbin/rtl8363-init
	echo "rescue switch init: rtl8363-init ($(sha256sum "$RTL8363_INIT" | cut -c1-16))"
else
	echo "WARNING: no RTL8363_INIT: the rescue has no wired network"
fi
sed -i 's|^root:[^:]*:|root:*:|' $R/etc/shadow
if [ -n "${AUTHORIZED_KEYS:-}" ] && [ -s "$AUTHORIZED_KEYS" ]; then
	mkdir -p $R/root/.ssh; cp "$AUTHORIZED_KEYS" $R/root/.ssh/authorized_keys
	chmod 700 $R/root $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys
	echo "rescue ssh key: AUTHORIZED_KEYS (test build, do not publish)"
else
	echo "rescue ssh: none (no AUTHORIZED_KEYS)"
fi
for f in /sbin/init /sbin/switch_root /sbin/findfs /sbin/blkid /sbin/e2fsck /usr/sbin/resize2fs /usr/sbin/dumpe2fs \
	/usr/sbin/dropbear /usr/share/udhcpc/default.script; do
	[ -e "$R$f" ] || { echo "mkinitramfs.sh: $f is missing in the initramfs"; exit 1; }
done
echo uc-pxx-rescue > $R/etc/hostname
rm -rf $R/var/cache/apk/* $R/lib/apk/db/scripts.tar $R/usr/share/man $R/usr/share/doc
apk add -q --no-cache cpio > /dev/null
(cd $R && find . | sort | cpio -o -H newc -R 0:0 --quiet) > "$OUT"
[ -n "${UIDGID:-}" ] && chown "$UIDGID" "$OUT"
ls -l "$OUT"
sha256sum "$OUT"
