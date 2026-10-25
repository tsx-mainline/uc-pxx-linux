#!/bin/sh
# Runs INSIDE an aarch64 Alpine container (see build-rootfs.sh), as root, with
# the repository at /w.
# Env:
#   ALPINE      Alpine branch, for example v3.24
#   KVER        module directory name(s) under /modules/lib/modules, separated
#               by spaces, or empty. The image takes such a tree only when no
#               kernel package has it.
#   OUT         output folder
#   UIDGID      owner of the outputs
#   IMG_MB      ext4 size in MiB (empty: the content plus IMG_HEADROOM_MB)
#   TSX_APK_URL base URL of this project's apk repository. The script writes
#               it into /etc/apk/repositories of the panel and never fetches it.
#   TSX_APK_LOCAL  required: a local copy of the published tree of that
#               repository, <ALPINE>/common and <ALPINE>/uc-pxx. The image
#               installs the profile meta package (uc-pxx-console, uc-pxx-kiosk
#               or uc-pxx-ha) and the packages of packages-tsx.txt from it.
#               check-apk-tree.sh stops the build when the tree lacks one of
#               them, for example the private package uc-pxx-board.
#   AUTHORIZED_KEYS  optional, test builds only
#   TSX_COMMON  optional: a checkout of tsx-linux-common. Its
#               splash/mksplash.sh renders the sizes of UC_PXX_SPLASH_SIZES
#               into /usr/share/tsx/splash (see below)
#   UC_PXX_SPLASH_SIZES  optional: extra splash sizes (WxH, separated by
#               spaces). Empty (the default): only the images of the package
#   TSX_BUILD_ID
#   TSX_DEV_ROOT_HASH  optional crypt(3) hash that becomes the root password
#               of the image, for our own test builds only. Without it the
#               image has no root password (docs/rootfs.md "Root login").
#   PROFILE     console, kiosk or ha (default ha). It decides what the image
#               holds. profiles/*.list, profile.sh and docs/rootfs.md
#               "Profiles" say what each profile has.
#   UC_PXX_DEV_OVERLAY  TEST ONLY. 1 builds without the uc-pxx packages
#               (docs/rootfs.md "Test build without the uc-pxx packages"). It
#               needs UC_PXX_BOOTCTL, UC_PXX_REBOOT and RTL8363_INIT (build-rootfs.sh).
#   UC_PXX_DEV_COMMON  TEST ONLY, with UC_PXX_DEV_OVERLAY=1 and TSX_COMMON.
#               1 copies the script files of the TSX_COMMON checkout over the
#               files of the installed common packages, so the image has
#               the common commits that are not published yet.
# The script compiles nothing. It copies only the files of profiles/image.list
# (fstab, inittab, the profile marker) and the splash images of
# UC_PXX_SPLASH_SIZES. The packages own all other files (docs/rootfs.md "Build the image").
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
R=/build/rootfs; mkdir -p /build
CACHE=/build/pip; mkdir -p $CACHE
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
ARCH=aarch64
log() { echo "== $*"; }
[ "$(apk --print-arch)" = $ARCH ] || { echo "mkrootfs.sh: this container is $(apk --print-arch), not $ARCH"; exit 1; }

# The profile of the image. has KIND NAME asks the lists in profiles/.
PROFILE=${PROFILE:-ha}
sh "$HERE/profile.sh" includes "$PROFILE" >/dev/null || exit 1
has() { sh "$HERE/profile.sh" has "$PROFILE" "$1" "$2"; }
log "profile $PROFILE"
[ -n "${TSX_APK_LOCAL:-}" ] || { echo "TSX_APK_LOCAL is required (a tsx-aports published tree with $ALPINE/common and $ALPINE/uc-pxx, see rootfs/fetch-apk-tree.sh)"; exit 1; }
DEV=${UC_PXX_DEV_OVERLAY:-}
# The reviewed uc-pxx-bootctl binary (docs/boot-control.md). The DEV mode
# installs only this exact file.
BOOTCTL_SHA256=38fea6d32412e7977ebc5845b138dc1c8c2df8555dae0b64b47f8a851b45e2d7
if [ "$DEV" = 1 ]; then
	log "TEST BUILD (UC_PXX_DEV_OVERLAY=1): no uc-pxx packages, the repository files instead. Never publish this image."
	[ -r "${UC_PXX_BOOTCTL:-}" ] || { echo "UC_PXX_DEV_OVERLAY=1: no UC_PXX_BOOTCTL"; exit 1; }
	[ -r "${UC_PXX_REBOOT:-}" ] || { echo "UC_PXX_DEV_OVERLAY=1: no UC_PXX_REBOOT"; exit 1; }
	[ -r "${RTL8363_INIT:-}" ] || { echo "UC_PXX_DEV_OVERLAY=1: no RTL8363_INIT"; exit 1; }
	sum=$(sha256sum "$UC_PXX_BOOTCTL" | cut -d' ' -f1)
	[ "$sum" = "$BOOTCTL_SHA256" ] || { echo "ERROR: UC_PXX_BOOTCTL has sha256 $sum, the reviewed binary is $BOOTCTL_SHA256"; exit 1; }
	log "uc-pxx-bootctl: sha256 $sum (the reviewed binary)"
else
	log "build from packages: uc-pxx-$PROFILE"
fi

printf '%s/%s/main\n%s/%s/community\n' "$MIRROR" "$ALPINE" "$MIRROR" "$ALPINE" > /etc/apk/repositories
apk update -q

# This project's apk repository (tsx-aports). The panel lists it first in
# /etc/apk/repositories at TSX_APK_URL (panel.conf APK_URL overrides that on
# the panel, tsx-config apply). The image gets the packages of the repository
# (the meta package and packages-tsx.txt) only from a LOCAL copy of the
# published tree (TSX_APK_LOCAL): the build never depends on TSX_APK_URL being
# reachable.
TSX_APK_URL=${TSX_APK_URL:-https://tsx-aports.unexceptional.net}; TSX_APK_URL=${TSX_APK_URL%/}
# The DEV mode uses only the common category.
TSX_CATS="common uc-pxx"; [ "$DEV" = 1 ] && TSX_CATS=common
for c in $TSX_CATS; do
	[ -r "$TSX_APK_LOCAL/$ALPINE/$c/$ARCH/APKINDEX.tar.gz" ] || { echo "TSX_APK_LOCAL: no $ALPINE/$c/$ARCH/APKINDEX.tar.gz under $TSX_APK_LOCAL"; exit 1; }
done
# The board package and the meta packages are not in the public tree. Stop here
# with a clear message when the tree lacks one of them.
if [ "$DEV" != 1 ]; then
	sh "$HERE/check-apk-tree.sh" "$TSX_APK_LOCAL" "$PROFILE" || { echo "ERROR: the tree $TSX_APK_LOCAL lacks packages that the $PROFILE image needs (docs/rootfs.md \"Where the packages come from\")"; exit 1; }
fi
apk add -q --no-cache e2fsprogs tar gzip zstd >/dev/null

log "install packages ($ALPINE, $ARCH)"
rm -rf $R; mkdir -p $R/etc/apk/keys
# trust this project's signing key (the same .pub the tsx-keys package ships)
cp "$HERE"/overlay/etc/apk/keys/*.rsa.pub /etc/apk/keys/
cp -a /etc/apk/keys/. $R/etc/apk/keys/
# The profile picks the packages (profiles/*.list). The lines keep the order
# of packages.txt and packages-tsx.txt.
PKGS=$(sh "$HERE/profile.sh" packages "$PROFILE" "$HERE/packages.txt" | tr '\n' ' ')
TSXPKGS=$(sh "$HERE/profile.sh" packages "$PROFILE" "$HERE/packages-tsx.txt" | tr '\n' ' ')
# The profile meta package pulls the packages that hold the panel software.
if [ "$DEV" = 1 ]; then
	# no uc-pxx packages: the common packages that the meta package will pull
	TSXPKGS=$(printf '%s\n' $TSXPKGS | grep -v '^uc-pxx-' | tr '\n' ' ')
	for l in $(sh "$HERE/profile.sh" includes "$PROFILE"); do
		TSXPKGS="$TSXPKGS $(awk -v p="$l" '$1 == p { print $2 }' "$HERE/dev/common-packages.list" | tr '\n' ' ')"
	done
else
	TSXPKGS="$TSXPKGS uc-pxx-$PROFILE"
fi
log "tsx-aports packages from $TSX_APK_LOCAL: $TSXPKGS"
# uc-pxx-chromium (if listed) provides chromium, so Alpine chromium stays out
if printf '%s\n' $TSXPKGS | grep -qx uc-pxx-chromium; then
	PKGS=$(sh "$HERE/profile.sh" packages "$PROFILE" "$HERE/packages.txt" | grep -vx chromium | tr '\n' ' ')
fi
PKGS="$PKGS $TSXPKGS"
: > /build/repositories
for c in $TSX_CATS; do printf '%s/%s/%s\n' "$TSX_APK_LOCAL" "$ALPINE" "$c" >> /build/repositories; done
cat /etc/apk/repositories >> /build/repositories
apk add --root $R --initdb --no-cache -q --keys-dir /etc/apk/keys \
	--repositories-file /build/repositories $PKGS
cp -a /etc/apk/keys $R/etc/apk/
# the panel's list: this project's two repositories FIRST (common + uc-pxx,
# never another platform's). The block, marker line included, is what
# tsx-config apply writes.
{
	echo "# tsx-aports (tsx-config apply; panel.conf APK_URL)"
	echo "$TSX_APK_URL/$ALPINE/common"
	echo "$TSX_APK_URL/$ALPINE/uc-pxx"
	cat /etc/apk/repositories
} > $R/etc/apk/repositories

if [ "$DEV" = 1 ]; then
	# TEST ONLY: the files that the packages uc-pxx-board, uc-pxx-leds and
	# uc-pxx-boot-tools will own, straight from the repository
	if [ "${UC_PXX_DEV_COMMON:-}" = 1 ]; then
		# TEST ONLY: the common checkout over the published common packages.
		# Each folder of tsx-linux-common is the root of one package (the
		# APKBUILDs of tsx-aports). Only the folders of installed packages
		# count, and in them only etc/ and usr/ (the other folders are
		# sources). The compiled programs stay as packaged. The board files
		# below win over these files.
		[ -d "${TSX_COMMON:-}/base" ] || { echo "UC_PXX_DEV_COMMON=1 needs TSX_COMMON"; exit 1; }
		log "DEV: common files from TSX_COMMON over the packages"
		: > /build/dev-common.list
		for m in base:tsx-base autoupdate:tsx-autoupdate buttons:tsx-buttons kiosk:tsx-kiosk setup:tsx-setup \
			ha:tsx-ha panel-app:tsx-panel-app sendspin:tsx-sendspin rescue:tsx-rescue-ui; do
			d=${m%%:*} pkg=${m#*:}
			[ -d "$TSX_COMMON/$d" ] && apk info --root $R -e "$pkg" > /dev/null 2>&1 || continue
			(cd "$TSX_COMMON/$d" && find ./etc ./usr -type f 2>/dev/null) |
			while read -r f; do
				t=${f#./}
				cmp -s "$TSX_COMMON/$d/$t" "$R/$t" && continue
				[ -e "$R/$t" ] && why=changed || why=new
				install -D -m "$(stat -c %a "$TSX_COMMON/$d/$t")" -o 0 -g 0 "$TSX_COMMON/$d/$t" "$R/$t"
				chmod go-w "$R/$t"
				echo "$why $pkg /$t" | tee -a /build/dev-common.list
			done
		done
		# tsx-ha installs the ESPHome shim in /opt/lva/shim (install-lva.sh
		# below copies it from there)
		if apk info --root $R -e tsx-ha > /dev/null 2>&1 && [ -d "$TSX_COMMON/ha/voice/shim" ]; then
			(cd "$TSX_COMMON/ha/voice/shim" && find . -type f -name '*.py') | while read -r f; do
				t=opt/lva/shim/${f#./}
				cmp -s "$TSX_COMMON/ha/voice/shim/$f" "$R/$t" && continue
				[ -e "$R/$t" ] && why=changed || why=new
				install -D -m 644 -o 0 -g 0 "$TSX_COMMON/ha/voice/shim/$f" "$R/$t"
				echo "$why tsx-ha /$t" | tee -a /build/dev-common.list
			done
		fi
		mkdir -p $R/etc/tsx
		{ echo "TEST BUILD (UC_PXX_DEV_COMMON=1): these files come from a tsx-linux-common checkout, not from the packages."
		  cat /build/dev-common.list; } > $R/etc/tsx/dev-common-overlay
	fi
	log "DEV: rootfs/overlay, packages/uc-pxx-leds/root, uc-pxx-bootctl, rtl8363-init"
	for d in "$HERE/overlay" "$TOP/packages/uc-pxx-leds/root"; do
		(cd "$d" && tar --owner=0 --group=0 --numeric-owner -cf - .) | tar -C $R -xpf -
	done
	install -m 755 -o 0 -g 0 "$UC_PXX_BOOTCTL" $R/usr/sbin/uc-pxx-bootctl
	install -m 755 -o 0 -g 0 "$RTL8363_INIT" $R/usr/sbin/rtl8363-init
	# the last step of uc-pxx-reboot (the script comes with rootfs/overlay)
	install -D -m 755 -o 0 -g 0 "$UC_PXX_REBOOT" $R/usr/libexec/uc-pxx-reboot-syscall
	[ "$(sha256sum $R/usr/sbin/uc-pxx-bootctl | cut -d' ' -f1)" = "$BOOTCTL_SHA256" ] || { echo "ERROR: uc-pxx-bootctl changed in the copy"; exit 1; }
	mkdir -p $R/etc/tsx
	echo "TEST BUILD (UC_PXX_DEV_OVERLAY=1), not from the uc-pxx packages. Do not publish." > $R/etc/tsx/dev-overlay
fi

# The splash images (docs/boot.md "The boot splash"). The package tsx-splash
# has images up to 1280x800. tsx-splash draws the largest image that fits,
# centered, on the 1920x1200 screen of the UC-P10: a full "show" after the
# orientation changed, and the background of the kiosk (tsx-splash png). The
# kiosk scale is 1.5, so the 1280x800 image has the physical size of the
# TSW 10" panels. UC_PXX_SPLASH_SIZES adds other sizes (WxH, separated by
# spaces) with mksplash.sh of tsx-linux-common. It is empty by default.
if [ -d $R/usr/share/tsx/splash ] && [ -n "${UC_PXX_SPLASH_SIZES:-}" ]; then
	[ -n "${TSX_COMMON:-}" ] || { echo "ERROR: UC_PXX_SPLASH_SIZES needs TSX_COMMON"; exit 1; }
	log "splash images $UC_PXX_SPLASH_SIZES (mksplash.sh of tsx-linux-common)"
	sh "$TSX_COMMON/splash/mksplash.sh" /build/board-splash $UC_PXX_SPLASH_SIZES > /dev/null
	for sz in $UC_PXX_SPLASH_SIZES; do
		install -m 644 -o 0 -g 0 /build/board-splash/splash-$sz.ppm $R/usr/share/tsx/splash/
	done
	rm -rf /build/board-splash
fi

log "image files ($PROFILE)"
# The packages own the files of the panel software. The image keeps only its
# own files (profiles/image.list).
sh "$HERE/profile.sh" stage "$PROFILE" $R
mkdir -p $R/data   # the data partition's mount point (fstab, tsx-data)
# the build's repository URL: tsx-config apply falls back to it when
# panel.conf has no APK_URL
printf '%s\n' "$TSX_APK_URL" > $R/etc/tsx/apk-url.default
# build id for tsx-autoupdate / the HA update entity (installed_version)
printf '%s\n' "${TSX_BUILD_ID:-$(date -u +%Y%m%d%H%M)}" > $R/etc/tsx/build-id
# The floor of the boot clock. The service hwclock sets the clock from the
# RTC of the RK808. The RTC keeps the time over a reboot, but it has no backup
# battery and reads a date in 2013 after a power cut. Then uc-pxx-clock sets
# the clock to the mtime of this file and writes the RTC. So a new image never
# boots earlier than its build time (/etc/periodic/15min/tsx-savetime keeps
# the file current while NTP has the time)
mkdir -p $R/var/lib/misc && touch $R/var/lib/misc/openrc-shutdowntime
if has step lva; then
log "Home Assistant device (tsx-esphome) and voice satellite (linux-voice-assistant)"
# The TensorFlow Lite C library for the wake word models comes from the
# tensorflow-lite-c package (tsx-aports, packages-tsx.txt). The package tsx-ha
# ships install-lva.sh and the ESPHome shim. The script copies the shim from
# the directory next to it, and it first deletes /opt/lva. So run it from a
# copy of both. The script downloads pinned Python wheels, so a package cannot
# hold its result. No panel runs it.
[ -x $R/usr/share/tsx/install-lva.sh ] || { echo "the tsx-ha package did not install /usr/share/tsx/install-lva.sh"; exit 1; }
rm -rf /build/lva-src; mkdir -p /build/lva-src
cp $R/usr/share/tsx/install-lva.sh /build/lva-src/
cp -a $R/opt/lva/shim /build/lva-src/shim
ARCH=aarch64 LVA_CACHE=$CACHE TFLITE_SO=/usr/lib/libtensorflowlite_c.so sh /build/lva-src/install-lva.sh $R
fi
chown -R 0:0 $R/etc $R/usr/local

# every binary of the packages must find its shared libraries in the image
# (a package missing from packages.txt only shows up on the panel otherwise:
# "Error loading shared library")
log "shared library check"
BINS="/usr/local/sbin/tsx-idled /usr/local/bin/tsx-splash"
has svc kiosk && BINS="$BINS /usr/local/bin/tsx-overlay"
[ -x $R/usr/bin/sendspin-cli ] && BINS="$BINS /usr/bin/sendspin-cli"
for bin in $BINS; do
	out=$(chroot $R /lib/ld-musl-aarch64.so.1 --list "$bin" 2>&1) || true
	if printf '%s\n' "$out" | grep -qE 'Error (loading|relocating)|not found'; then
		printf '%s\n' "$out" | head -n 5
		echo "ERROR: $bin: missing shared libraries (add the package to packages.txt)"; exit 1
	fi
done

log "users, services"
# The profile decides which services start and which users exist. The lists
# are in profiles/*.list. The chroot shell reads them from its environment.
TSX_SVC_BOOT=$(sh "$HERE/profile.sh" entries "$PROFILE" svc | awk '$1 == "boot" { print $2 }' | tr '\n' ' ')
TSX_SVC_DEFAULT=$(sh "$HERE/profile.sh" entries "$PROFILE" svc | awk '$1 == "default" { print $2 }' | tr '\n' ' ')
if [ "$DEV" = 1 ]; then
	# The published tsx-autoupdate has no board hook. An update must arm slot A
	# first (uc-pxx-arm-slot, docs/boot-control.md "The update rule"). So a
	# DEV image does not start it.
	TSX_SVC_DEFAULT=$(printf '%s\n' $TSX_SVC_DEFAULT | grep -vx tsx-autoupdate | tr '\n' ' ')
	log "DEV: tsx-autoupdate is not started (no board hook in the published common packages)"
fi
TSX_USERS=$(sh "$HERE/profile.sh" entries "$PROFILE" user | tr '\n' ' ')
case "$PROFILE" in console) TSX_HOSTNAME=tsx-console;; *) TSX_HOSTNAME=tsx-kiosk;; esac
export TSX_SVC_BOOT TSX_SVC_DEFAULT TSX_USERS TSX_HOSTNAME
chroot $R /bin/sh -e <<'CH'
case " $TSX_USERS " in *" kiosk "*)
	addgroup -S seat 2>/dev/null || true
	addgroup -S render 2>/dev/null || true
	# The package tsx-kiosk makes this user in its pre-install script.
	getent passwd kiosk >/dev/null || adduser -D -H -h /var/lib/kiosk -s /sbin/nologin -g "kiosk browser" kiosk
	for g in video input seat render audio; do addgroup kiosk $g 2>/dev/null || true; done
	mkdir -p /var/lib/kiosk && chown kiosk:kiosk /var/lib/kiosk;;
esac
# on-panel setup page (docs/rootfs.md "Setup page"): deliberately its OWN
# unprivileged user, not "kiosk" -- it parses HTTP from the LAN before any
# pairing has happened, a smaller and different trust boundary than the
# always-unsandboxed browser, and it never needs kiosk's video/input group
# access. It has no home directory and talks to root only through tsx-setup-helper's
# FIFOs (group tsx-setup, created by that service).
case " $TSX_USERS " in *" tsx-setup "*)
	getent passwd tsx-setup >/dev/null || adduser -D -H -s /sbin/nologin -g "on-panel setup page" tsx-setup;;
esac
for s in devfs dmesg udev udev-trigger udev-settle; do rc-update add $s sysinit; done
for s in root localmount modules sysctl hostname bootmisc syslog hwclock seedrng udev-postmount machine-id $TSX_SVC_BOOT; do
	[ -e /etc/init.d/$s ] && rc-update add $s boot || { echo "MISSING boot service $s"; exit 1; }
done
for s in $TSX_SVC_DEFAULT; do
	[ -e /etc/init.d/$s ] && rc-update add $s default || { echo "MISSING service $s"; exit 1; }
done
for s in mount-ro killprocs savecache; do rc-update add $s shutdown; done
echo "$TSX_HOSTNAME" > /etc/hostname
printf '127.0.0.1\tlocalhost %s\n::1\t\tlocalhost\n' "$TSX_HOSTNAME" > /etc/hosts
mkdir -p /etc/crontabs && touch /etc/crontabs/root
# ssh: root with password or key (change on deploy, panel.conf
# ROOT_PASSWORD_HASH / SSH_AUTHORIZED_KEY)
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
# allow ssh -L (DevTools tunnel for the first HA login). Alpine ships "no"
sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding local/' /etc/ssh/sshd_config
grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
CH
# Root password (docs/rootfs.md "Root login"). A public image has none: the
# field in /etc/shadow is locked ("*"), never empty. The installer stops unless
# it gets a root password or an SSH key. It puts the hash of the password and
# the key in panel.conf, and the first boot applies them (tsx-config apply).
# With a key only, the password stays locked until a person sets one over ssh.
# Only a test build sets a fixed password: TSX_DEV_ROOT_HASH, a crypt(3) hash.
if [ -n "${TSX_DEV_ROOT_HASH:-}" ]; then
	case "$TSX_DEV_ROOT_HASH" in \$6\$*) ;; *) echo "TSX_DEV_ROOT_HASH is not a sha-512 crypt hash (\$6\$...)"; exit 1;; esac
	sed -i "s|^root:[^:]*:|root:$TSX_DEV_ROOT_HASH:|" $R/etc/shadow
	ROOT_PW_RESULT="TSX_DEV_ROOT_HASH (test build, do not publish)"
else
	sed -i "s|^root:[^:]*:|root:*:|" $R/etc/shadow
	ROOT_PW_RESULT="none (locked until the installer or ssh sets one)"
fi
echo "root password: $ROOT_PW_RESULT"
# AUTHORIZED_KEYS (optional) bakes a key into the image. It is a test option.
if [ -n "${AUTHORIZED_KEYS:-}" ] && [ -s "$AUTHORIZED_KEYS" ]; then
	mkdir -p $R/root/.ssh; cp "$AUTHORIZED_KEYS" $R/root/.ssh/authorized_keys; chmod 700 $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys
fi

log "trim"
# /etc/machine-id: the dbus package's post-install trigger writes one id
# into the image, which every panel flashed from it would then share. Ship it
# empty: OpenRC's machine-id service (boot runlevel) fills an empty one once,
# on each unit's first boot.
: > $R/etc/machine-id
# Chromium UI locales: keep en-US only
[ -d $R/usr/lib/chromium/locales ] && find $R/usr/lib/chromium/locales -name '*.pak' ! -name 'en-US.pak' -delete
# man pages / doc / info: never read on a headless kiosk
rm -rf $R/usr/share/man $R/usr/share/doc $R/usr/share/info
# apk's own index cache. It is cleared again before the tarball
rm -rf $R/var/cache/apk/* $R/lib/apk/db/scripts.tar
[ -d $R/usr/share/locale ] && find $R/usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name C -exec rm -rf {} +
# sway-wallpapers: install_if-bound to sway, unused (the kiosk's background
# is the boot splash, usr/local/bin/kiosk-session)
rm -rf $R/usr/share/backgrounds/sway
# python bytecode caches: the -pyc subpackages are install_if-bound to
# python3; the interpreter recompiles at the first import
find $R/usr/lib/python3* -depth \( -type d -name '__pycache__' -o -type f -name '*.pyc' \) -exec rm -rf {} +

# Kernel modules. The kernel packages own the trees in /lib/modules. A release
# build (.github/workflows/release.yml) also stages the modules of the kernel
# that it builds, and the build copies such a tree when no package has it.
copied=0
for kv in ${KVER:-}; do
	if [ -d "$R/lib/modules/$kv" ]; then
		# installed (and owned) by uc-pxx-kernel-<flavor>: keep the package's tree
		log "kernel modules $kv: from its uc-pxx-kernel package"
		copied=$((copied + 1))
	elif [ -d "/modules/lib/modules/$kv" ]; then
		echo "WARNING: kernel modules $kv: no uc-pxx-kernel package in $TSX_APK_LOCAL has them, so they are copied as unowned files"
		log "kernel modules $kv"
		mkdir -p $R/lib/modules
		cp -a "/modules/lib/modules/$kv" $R/lib/modules/
		rm -f "$R/lib/modules/$kv/build" "$R/lib/modules/$kv/source"
		depmod -b $R "$kv" 2>/dev/null || true
		copied=$((copied + 1))
	else
		echo "WARNING: no modules for $kv at /modules/lib/modules/$kv"
	fi
done
if [ "$copied" -gt 0 ]; then
	chown -R 0:0 $R/lib/modules
else
	log "no kernel modules staged (KVER=${KVER:-unset}), the kernel package has them"
fi

# The kernel package must carry the pinned kernel (kernel/KERNEL_REV.lts). An
# old package in the local tree would put a stale /boot/uc-pxx-lts.img in the
# image.
if [ "$DEV" = 1 ]; then
	# no kernel package: the boot image comes from the kernel build directly
	short=$(grep -v '^#' "$TOP/kernel/KERNEL_REV.lts" | head -n 1 | cut -c1-12)
	for kv in $(ls $R/lib/modules 2>/dev/null); do
		case $kv in *-g"$short") ;; *) echo "ERROR: the module tree $kv is not from the pinned kernel $short"; exit 1;; esac
	done
	log "DEV: no kernel package, module trees: $(ls $R/lib/modules 2>/dev/null | tr '\n' ' ')"
else
	log "check the kernel package against kernel/KERNEL_REV.lts"
	sh "$HERE/check-kernel-pins.sh" "$R" "$TOP/kernel" || { echo "ERROR: the kernel package in $TSX_APK_LOCAL does not match the kernel pin"; exit 1; }
fi

log "manifest and sizes"
mkdir -p "$OUT"
apk info --root $R -v 2>/dev/null | sort > "$OUT/rootfs.manifest"
{
	echo "rootfs total: $(du -sm $R | cut -f1) MiB, $(wc -l < "$OUT/rootfs.manifest") packages"
	echo "largest packages (installed size):"
	apk info --root $R -s $(apk info --root $R 2>/dev/null) 2>/dev/null | awk '
		/ installed size:$/ {p=$1; sub(/-[0-9].*$/, "", p); next}
		NF==2 && p != "" {v=$1; u=$2; if (u=="KiB") v/=1024; if (u=="GiB") v*=1024; if (u=="B") v/=1048576; printf "%8.1f MiB  %s\n", v, p; p=""}' | sort -rn | head -25
	echo "largest directories:"
	du -xm -d 3 $R/usr $R/lib $R/opt 2>/dev/null | sort -rn | head -15 | sed "s|$R||"
	echo "profile: $PROFILE"
	if [ "$DEV" = 1 ]; then echo "image source: TEST BUILD (UC_PXX_DEV_OVERLAY=1), common packages and the repository files"
	else echo "image source: packages (uc-pxx-$PROFILE)"; fi
	echo "root password: $ROOT_PW_RESULT"
	echo "tsx-aports: installed from a local tree: $TSXPKGS"
	echo "tsx-aports: panel repository URL $TSX_APK_URL/$ALPINE/{common,uc-pxx}"
	ls $R/lib/modules 2>/dev/null | sed 's/^/kernel modules: /'
} > "$OUT/rootfs.sizes"
cat "$OUT/rootfs.sizes"

# the apk info calls above fill $R/var/cache/apk again, so clear it again
rm -rf $R/var/cache/apk/*

# The shared library check above runs tsx-idled in the chroot, and a build
# step can leave its log. A panel makes a new log at its first start, so the
# image ships with none.
rm -f $R/var/log/tsx-idled.log

log "tarball"
tar -C $R --numeric-owner -cpf - . | gzip -6 > "$OUT/rootfs.tar.gz"
# The ext4 image is compact (the content plus headroom). The initramfs grows
# the file system to fill system_a (1792 MiB) on the first boot. So the image
# must leave room for that to be worth anything.
used=$(du -sm $R | cut -f1)
IMG_MB=${IMG_MB:-$(( (used * 105 / 100) + ${IMG_HEADROOM_MB:-256} ))}
[ "$IMG_MB" -le 1700 ] || { echo "rootfs.ext4 would be $IMG_MB MiB: too large for system_a (1792 MiB)"; exit 1; }
log "ext4 image (${IMG_MB} MiB, label tsxroot; content ${used} MiB)"
rm -f "$OUT/rootfs.ext4"
mke2fs -q -t ext4 -L tsxroot -m 1 -d $R "$OUT/rootfs.ext4" "${IMG_MB}M"
e2fsck -fn "$OUT/rootfs.ext4" >/dev/null && echo "e2fsck clean"
(cd "$OUT" && sha256sum rootfs.tar.gz rootfs.ext4 > rootfs.sha256)
chown "$UIDGID" "$OUT"/rootfs.*
ls -ls "$OUT"/rootfs.*
