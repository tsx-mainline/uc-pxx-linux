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
#   TSX_COMMON       required: a checkout of tsx-linux-common. The rescue
#                    tools come from its rescue/usr/sbin: tsx-rescue-status,
#                    tsx-confont, tsx-rescue-backlight, tsx-rescue-login,
#                    tsx-data-backup and tsx-data-restore
#   UC_PXX_BOOTCTL   required: the static aarch64 uc-pxx-bootctl
#                    (tools/uc-pxx-bootctl/build.sh). The rescue screen and
#                    uc-pxx-install-rootfs only read the A/B state with it.
#                    Its sha256 must be the reviewed one
#                    (docs/boot-control.md), or the build stops
#   UC_PXX_REBOOT    required: the static aarch64 uc-pxx-reboot-syscall
#                    (tools/uc-pxx-reboot/build.sh). It is the last step of
#                    uc-pxx-reboot (the script of rootfs/overlay). /init runs
#                    `uc-pxx-reboot loader` when Volume down + Mute are held
#   RTL8363_INIT     optional: the static aarch64 rtl8363-init
#                    (tools/rtl8363-init/build.sh). Without it the rescue has
#                    no wired network
#   TSX_APK_LOCAL    optional: the apk tree of tsx-aports. The boot splash
#                    (tsx-splash of tsx-linux-common) comes from its
#                    <ALPINE>/common, checked with the key of the image.
#                    Without it the initramfs has no boot splash
#   UC_PXX_SPLASH_SIZES  optional: extra splash sizes (WxH, separated by
#                    spaces) that the build renders with mksplash.sh. Empty
#                    (the default): the splash is the 1280x800 image of the
#                    package, centered on the 1920x1200 screen of the UC-P10
#   UIDGID           owner of OUT
# TEST BUILDS ONLY (never in an image that goes to a user):
#   TSX_DEV_RESCUE_HASH  a sha-512 crypt(3) hash that becomes the root password
#                    of the rescue
#   TSX_DEV_RESCUE_KEYS  a file with ssh public keys that the rescue dropbear
#                    accepts at every boot
# The image has no root password and no ssh key. tsx-rescue-login chooses the
# login at each rescue boot: the root hash and the ssh key of the panel from
# the root file system, or a one-time password on the rescue screen. The shell
# on the serial console needs no login.
set -eu
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(apk --print-arch)" = aarch64 ] || { echo "mkinitramfs.sh: this container is $(apk --print-arch), not aarch64"; exit 1; }
# the reviewed uc-pxx-bootctl (the same sha256 as rootfs/mkrootfs.sh, rule 9 of the safety rules)
BOOTCTL_SHA256=38fea6d32412e7977ebc5845b138dc1c8c2df8555dae0b64b47f8a851b45e2d7
[ -n "${UC_PXX_BOOTCTL:-}" ] && [ -x "$UC_PXX_BOOTCTL" ] || { echo "mkinitramfs.sh: UC_PXX_BOOTCTL (the static uc-pxx-bootctl) is required"; exit 1; }
[ "$(sha256sum "$UC_PXX_BOOTCTL" | cut -d' ' -f1)" = "$BOOTCTL_SHA256" ] || { echo "mkinitramfs.sh: UC_PXX_BOOTCTL is not the reviewed uc-pxx-bootctl ($BOOTCTL_SHA256)"; exit 1; }
[ -n "${UC_PXX_REBOOT:-}" ] && [ -x "$UC_PXX_REBOOT" ] || { echo "mkinitramfs.sh: UC_PXX_REBOOT (the static uc-pxx-reboot-syscall) is required"; exit 1; }
[ -n "${TSX_COMMON:-}" ] && [ -d "$TSX_COMMON/rescue/usr/sbin" ] || { echo "mkinitramfs.sh: TSX_COMMON (a tsx-linux-common checkout with rescue/usr/sbin) is required"; exit 1; }
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
printf '%s/%s/main\n%s/%s/community\n' "$MIRROR" "${ALPINE:-v3.24}" "$MIRROR" "${ALPINE:-v3.24}" > /etc/apk/repositories
R=/tmp/initramfs; rm -rf $R; mkdir -p $R
# e2fsprogs: e2fsck and dumpe2fs. e2fsprogs-extra: resize2fs. evtest: the key
# state for the loader mode (/init).
apk add --root $R --initdb --no-cache -q \
	--repositories-file /etc/apk/repositories --keys-dir /etc/apk/keys \
	alpine-baselayout busybox busybox-binsh dropbear e2fsprogs e2fsprogs-extra evtest
cp -a "$HERE"/overlay/. $R/
chmod 755 $R/init $R/etc/init.d/rcS $R/usr/sbin/uc-pxx-install-rootfs $R/usr/sbin/uc-pxx-rescue-help
# The shared rescue tools of tsx-linux-common (package tsx-rescue-ui). The
# board file is the one of the root file system: one source.
for f in tsx-rescue-status tsx-confont tsx-rescue-backlight tsx-rescue-login tsx-data-backup tsx-data-restore; do
	[ -f "$TSX_COMMON/rescue/usr/sbin/$f" ] || { echo "mkinitramfs.sh: $TSX_COMMON/rescue/usr/sbin/$f is missing"; exit 1; }
	install -D -m 755 "$TSX_COMMON/rescue/usr/sbin/$f" $R/usr/sbin/$f
done
echo "rescue tools: $(cd "$TSX_COMMON" && git describe --always --dirty 2>/dev/null || echo 'tsx-linux-common, no git')"
install -D -m 644 /w/rootfs/overlay/usr/local/lib/tsx/board.sh $R/usr/local/lib/tsx/board.sh
install -D -m 755 "$UC_PXX_BOOTCTL" $R/usr/sbin/uc-pxx-bootctl
install -D -m 755 "$UC_PXX_REBOOT" $R/usr/libexec/uc-pxx-reboot-syscall
install -D -m 755 /w/rootfs/overlay/usr/sbin/uc-pxx-reboot $R/usr/sbin/uc-pxx-reboot
# the watcher of Volume down + Mute (the rescue runs it with --rescue, inittab)
install -D -m 755 /w/rootfs/overlay/usr/local/sbin/uc-pxx-loader-key $R/usr/local/sbin/uc-pxx-loader-key
[ "$(sha256sum $R/usr/sbin/uc-pxx-bootctl | cut -d' ' -f1)" = "$BOOTCTL_SHA256" ] || { echo "mkinitramfs.sh: uc-pxx-bootctl changed in the copy"; exit 1; }
# Terminus bold console fonts for tsx-confont (SIL OFL 1.1). It picks the
# largest one that gives at least 80x25 cells on the console: 16x32 on the
# 1920x1200 console of the UC-P10 (120x37). The fonts are built in the build
# container and go into the initramfs uncompressed, for setfont.
apk add -q --no-cache font-terminus > /dev/null
mkdir -p $R/usr/share/tsx/consolefonts
for f in ter-116b ter-118b ter-120b ter-122b ter-124b ter-128b ter-132b; do
	zcat /usr/share/consolefonts/$f.psf.gz > $R/usr/share/tsx/consolefonts/$f.psf
done
# the version line of the rescue screen
mkdir -p $R/etc/tsx
echo "uc-pxx initramfs rescue (boot image)" > $R/etc/tsx/rescue-version
if [ -n "${RTL8363_INIT:-}" ]; then
	[ -x "$RTL8363_INIT" ] || { echo "mkinitramfs.sh: RTL8363_INIT=$RTL8363_INIT is not an executable"; exit 1; }
	install -m 755 "$RTL8363_INIT" $R/usr/sbin/rtl8363-init
	echo "rescue switch init: rtl8363-init ($(sha256sum "$RTL8363_INIT" | cut -c1-16))"
else
	echo "WARNING: no RTL8363_INIT: the rescue has no wired network"
fi
# The boot splash (docs/boot.md "The boot splash"): the program and the
# images of the package tsx-splash. /init always draws the landscape frame.
# The package has the 1280x800 image. tsx-splash draws it centered on the
# 1920x1200 screen of the UC-P10. The scale of the kiosk is 1.5, so the
# picture has the physical size of the TSW 10" panels. The fonts draw the
# status line. UC_PXX_SPLASH_SIZES adds other sizes (the hook for a later
# size, empty by default).
if [ -n "${TSX_APK_LOCAL:-}" ]; then
	A=${ALPINE:-v3.24}
	cp /w/rootfs/overlay/etc/apk/keys/*.rsa.pub /etc/apk/keys/
	printf '%s/%s/common\n' "$TSX_APK_LOCAL" "$A" > /tmp/splash-repos
	cat /etc/apk/repositories >> /tmp/splash-repos
	S=/tmp/splash-root; rm -rf $S; mkdir -p $S
	apk add --root $S --initdb --no-cache -q --repositories-file /tmp/splash-repos --keys-dir /etc/apk/keys tsx-splash
	install -D -m 755 $S/usr/local/bin/tsx-splash $R/usr/sbin/tsx-splash
	mkdir -p $R/usr/share/tsx/splash
	for f in font-16.psf font-24.psf splash-1280x800.ppm; do
		cp $S/usr/share/tsx/splash/$f $R/usr/share/tsx/splash/$f
	done
	echo "boot splash: $(apk info --root $S -v tsx-splash 2>/dev/null | head -n 1)"
	rm -rf $S
	if [ -n "${UC_PXX_SPLASH_SIZES:-}" ]; then
		[ -n "${TSX_COMMON:-}" ] && [ -r "$TSX_COMMON/splash/mksplash.sh" ] ||
			{ echo "mkinitramfs.sh: UC_PXX_SPLASH_SIZES needs TSX_COMMON with splash/mksplash.sh"; exit 1; }
		sh "$TSX_COMMON/splash/mksplash.sh" /tmp/board-splash $UC_PXX_SPLASH_SIZES > /dev/null
		for sz in $UC_PXX_SPLASH_SIZES; do
			cp /tmp/board-splash/splash-$sz.ppm $R/usr/share/tsx/splash/
			echo "boot splash: splash-$sz.ppm from mksplash.sh ($(sha256sum /tmp/board-splash/splash-$sz.ppm | cut -c1-16))"
		done
		rm -rf /tmp/board-splash
	fi
else
	echo "WARNING: no TSX_APK_LOCAL: the initramfs has no boot splash"
fi
# root: the field is locked. tsx-rescue-login sets the real login at boot.
if [ -n "${TSX_DEV_RESCUE_HASH:-}" ]; then
	case "$TSX_DEV_RESCUE_HASH" in \$6\$*) ;; *) echo "TSX_DEV_RESCUE_HASH is not a sha-512 crypt hash"; exit 1;; esac
	sed -i "s|^root:[^:]*:|root:$TSX_DEV_RESCUE_HASH:|" $R/etc/shadow
	echo "rescue root password: TSX_DEV_RESCUE_HASH (TEST BUILD, do not publish)"
else
	sed -i 's|^root:[^:]*:|root:*:|' $R/etc/shadow
	echo "rescue root password: none (tsx-rescue-login chooses at boot)"
fi
if [ -n "${TSX_DEV_RESCUE_KEYS:-}" ] && [ -s "$TSX_DEV_RESCUE_KEYS" ]; then
	mkdir -p $R/root/.ssh; cp "$TSX_DEV_RESCUE_KEYS" $R/root/.ssh/authorized_keys
	chmod 700 $R/root $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys
	echo "rescue ssh key: TSX_DEV_RESCUE_KEYS (TEST BUILD, do not publish)"
else
	echo "rescue ssh key: none (tsx-rescue-login chooses at boot)"
fi
for f in /sbin/init /sbin/switch_root /sbin/findfs /sbin/blkid /sbin/e2fsck /usr/sbin/resize2fs /usr/sbin/dumpe2fs \
	/usr/sbin/dropbear /usr/share/udhcpc/default.script /usr/sbin/tsx-rescue-status /usr/sbin/tsx-rescue-login \
	/usr/sbin/tsx-rescue-backlight /usr/sbin/tsx-confont /usr/sbin/tsx-data-backup /usr/sbin/uc-pxx-install-rootfs \
	/usr/sbin/uc-pxx-bootctl /usr/sbin/uc-pxx-reboot /usr/libexec/uc-pxx-reboot-syscall /usr/bin/evtest /usr/share/tsx/consolefonts/ter-132b.psf /usr/local/lib/tsx/board.sh; do
	[ -e "$R$f" ] || { echo "mkinitramfs.sh: $f is missing in the initramfs"; exit 1; }
done
echo uc-pxx-rescue > $R/etc/hostname
rm -rf $R/var/cache/apk/* $R/lib/apk/db/scripts.tar $R/usr/share/man $R/usr/share/doc
apk add -q --no-cache cpio > /dev/null
(cd $R && find . | sort | cpio -o -H newc -R 0:0 --quiet) > "$OUT"
[ -n "${UIDGID:-}" ] && chown "$UIDGID" "$OUT"
ls -l "$OUT"
sha256sum "$OUT"
