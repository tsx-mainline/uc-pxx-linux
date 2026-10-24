#!/bin/bash
# Build the rootfs of the UC-P10 (Alpine aarch64) from packages, and the boot
# initramfs, in docker with qemu-user binfmt (qemu-aarch64) on the build host.
#
#   ./build-rootfs.sh modules [MODULES.tar.gz|KBUILD_DIR ...]
#   ./build-rootfs.sh initramfs
#   ./build-rootfs.sh rootfs | all
#
# Outputs (out/): rootfs.tar.gz, rootfs.ext4 (compact, the initramfs grows it
# to fill system_a on the first boot), rootfs.manifest (exact package
# versions), rootfs.sizes and rootfs.sha256. "initramfs" writes
# out/initramfs.cpio (not compressed). ci/build-kernel.sh --initramfs builds it
# into the kernel Image (docs/boot.md "The boot initramfs").
#
# Env:
#   ALPINE      Alpine branch (default v3.24)
#   IMG_MB      size of rootfs.ext4 in MiB (default: the content plus
#               IMG_HEADROOM_MB, default 256, at most 1700 because system_a is 1792)
#   KVER        which staged module trees under modules/lib/modules/ go into
#               the rootfs (default: all of them, separated by spaces)
#   AUTHORIZED_KEYS  test builds only: ssh public keys that the rootfs (and
#               the rescue of the initramfs) accept at every boot, baked into
#               the image (default: rootfs/authorized_keys if it exists, never
#               committed)
#   RTL8363_INIT  the static aarch64 rtl8363-init (tools/rtl8363-init/build.sh).
#               "initramfs" puts it into the rescue. The DEV mode puts it into
#               the rootfs. The binary links with the Realtek SDK and is not
#               part of this repository.
#   UC_PXX_DEV_OVERLAY  TEST ONLY. 1 builds the rootfs without the uc-pxx
#               packages, which do not exist yet (docs/rootfs.md "Test build
#               without the uc-pxx packages"). The image then gets the Alpine
#               packages, the common packages of dev/common-packages.list, the
#               files of rootfs/overlay and packages/uc-pxx-leds/root,
#               UC_PXX_BOOTCTL and RTL8363_INIT. Never publish such an image.
#   UC_PXX_BOOTCTL  DEV mode: the static aarch64 uc-pxx-bootctl
#               (tools/uc-pxx-bootctl/build.sh). Its sha256 must be the
#               reviewed one (docs/boot-control.md), or the build stops.
#   PROFILE     what the rootfs holds (default ha): console (text login on the
#               panel screen and SSH), kiosk (console plus the browser kiosk) or
#               ha (kiosk plus the Home Assistant layer). profiles/*.list name
#               the files, packages and services of each profile
#               (docs/rootfs.md "Profiles").
#   TSX_DEV_ROOT_HASH  optional crypt(3) hash for the root password of the
#               image, for our own test builds only. Without it the image has
#               no root password and the installer sets one (docs/rootfs.md
#               "Root login"). A public image never uses it. Example:
#                 TSX_DEV_ROOT_HASH=$(openssl passwd -6 mypassword) ./build-rootfs.sh rootfs
#   TSX_APK_LOCAL  required for rootfs and all: a local copy of the published
#               tree of this project's apk repository (tsx-aports), the folder
#               that holds <ALPINE>/common and <ALPINE>/uc-pxx, for example
#               from rootfs/fetch-apk-tree.sh. The build installs the profile
#               meta package (uc-pxx-console, -kiosk or -ha), the packages of
#               packages-tsx.txt and the Alpine packages of packages.txt from
#               it. Nothing is compiled. The tree must hold the private
#               package uc-pxx-board. rootfs/check-apk-tree.sh stops the build
#               when it does not (docs/rootfs.md "Build the image").
#   TSX_APK_URL  this project's apk repository, see mkrootfs.sh: the panel
#               lists <url>/<ALPINE>/common and /uc-pxx first. The build never
#               fetches it.
#
# "modules" stages kernel modules for the rootfs from a modules tarball (the
# lib/modules/<release>/ tree of `make modules_install`, what the kernel
# build produces next to kernel.release) or from a kernel build directory
# (read only: *.ko, modules.order, modules.builtin*). The modules are
# stripped of debug info. Staging a release replaces that release and older
# trees of the same series (major.minor) only. The board needs no module to
# boot (docs/kernel.md "Everything is built in"). So most builds stage
# nothing.
#
# Downloads: Alpine packages from dl-cdn.alpinelinux.org (branch $ALPINE), the
# alpine:3.24 docker image, and the pinned, checksummed Python wheels that
# install-lva.sh of the package tsx-ha fetches. The versions are recorded in
# out/rootfs.manifest.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=$HERE/out; mkdir -p "$OUT"
ALPINE=${ALPINE:-v3.24}
# The build container is alpine:3.24 for aarch64, under its own local tag. A
# local "alpine:3.24" may be the image of another architecture (docker runs a
# local tag whatever --platform says). So the arm64 image is pulled by its
# digest from the alpine:3.24 manifest list and tagged IMAGE.
BASE_IMAGE=${BASE_IMAGE:-alpine:3.24}
IMAGE=${IMAGE:-uc-pxx-alpine:3.24}
PLATFORM=linux/arm64
MODULES=$HERE/modules
# "|| true": under pipefail a missing modules/lib/modules (the normal case
# before "modules" has run) must not end the script
KVER=${KVER:-$(ls "$MODULES/lib/modules" 2>/dev/null | tr '\n' ' ' || true)}
AUTHORIZED_KEYS=${AUTHORIZED_KEYS:-$HERE/authorized_keys}
UIDGID="$(id -u):$(id -g)"
need_binfmt() {
	[ -e "${BINFMT_DIR:-/proc/sys/fs/binfmt_misc}/qemu-aarch64" ] || { echo "need qemu-aarch64 binfmt (qemu-user-static)"; exit 1; }
	ensure_image
}
ensure_image() {
	local d
	[ "$(docker image inspect -f '{{.Architecture}}' "$IMAGE" 2>/dev/null)" = arm64 ] && return 0
	d=$(docker manifest inspect "$BASE_IMAGE" | python3 -c '
import json, sys
for m in json.load(sys.stdin)["manifests"]:
    if m["platform"]["architecture"] == "arm64" and m["platform"]["os"] == "linux":
        print(m["digest"]); break') || true
	[ -n "$d" ] || { echo "no linux/arm64 image in $BASE_IMAGE"; exit 1; }
	docker pull -q "${BASE_IMAGE%%:*}@$d" >/dev/null
	docker tag "${BASE_IMAGE%%:*}@$d" "$IMAGE"
	[ "$(docker image inspect -f '{{.Architecture}}' "$IMAGE")" = arm64 ] || { echo "$IMAGE is not arm64"; exit 1; }
	echo "build image: $IMAGE = ${BASE_IMAGE%%:*}@$d (linux/arm64)"
}

# stage_tree SRC_RELEASE_DIR RELEASE SOURCE_NOTE: copy one lib/modules/<rel>
# tree into $MODULES and replace the same series
stage_tree() {
	local src=$1 rel=$2 note=$3 ser old
	ser=$(echo "$rel" | cut -d. -f1-2)
	for old in "$MODULES/lib/modules/$ser".*; do
		[ -d "$old" ] || continue
		echo "modules: replacing staged tree ${old##*/}"; rm -rf "$old"
	done
	mkdir -p "$MODULES/lib/modules"
	cp -a "$src" "$MODULES/lib/modules/$rel"
	rm -f "$MODULES/lib/modules/$rel/build" "$MODULES/lib/modules/$rel/source"
	need_binfmt
	docker run --rm --platform $PLATFORM -v "$MODULES:/m" "$IMAGE" sh -c "
		apk add -q --no-cache binutils >/dev/null
		# modules built without debug info are already small, so strip what it can
		find /m/lib/modules/$rel -name '*.ko' -exec strip --strip-debug {} + 2>/dev/null
		chown -R $UIDGID /m/lib/modules/$rel"
	echo "modules for $rel: $(find "$MODULES/lib/modules/$rel" -name '*.ko' | wc -l) files, $(du -sh "$MODULES/lib/modules/$rel" | cut -f1)"
	# SOURCE: one line per staged release
	local r rest
	{ if [ -f "$MODULES/SOURCE" ]; then
		while read -r r rest; do
			if [ "$r" != "$rel" ] && [ -d "$MODULES/lib/modules/$r" ]; then echo "$r $rest"; fi
		done < "$MODULES/SOURCE"
	  fi
	  echo "$rel source: $note"; } > "$MODULES/SOURCE.new"
	mv "$MODULES/SOURCE.new" "$MODULES/SOURCE"
}

# modules from a tarball: exactly one lib/modules/<release>/ inside
modules_tar() {
	local tgz=$1 t rel
	t=$(mktemp -d)
	tar -C "$t" -xzf "$tgz"
	set -- "$t"/lib/modules/*/
	[ $# = 1 ] && [ -d "$1" ] || { echo "$tgz: expected exactly one lib/modules/<release>/"; rm -rf "$t"; return 1; }
	rel=$(basename "$1")
	[ -e "$1/modules.dep" ] || [ -e "$1/modules.order" ] || { echo "$tgz: $rel has no modules.dep/modules.order"; rm -rf "$t"; return 1; }
	stage_tree "${1%/}" "$rel" "$(basename "$tgz") (sha256 $(sha256sum "$tgz" | cut -c1-16))"
	rm -rf "$t"
}

# modules from a kernel build directory (read only)
modules_kbuild() {
	local kb=$1 rel one vm t D m
	rel=$(cat "$kb/include/config/kernel.release")
	# refuse stale modules: their vermagic must name the release of the kernel image
	one=$(find "$kb" -name '*.ko' ! -path '*/source/*' -print -quit)
	[ -n "$one" ] || { echo "no *.ko in $kb (run 'make modules' there first)"; return 1; }
	vm=$(grep -a -m1 -o 'vermagic=[^ ]*' "$one" | cut -d= -f2)
	[ "$vm" = "$rel" ] || { echo "stale modules in $kb: vermagic $vm, kernel $rel (rebuild modules there first)"; return 1; }
	t=$(mktemp -d)
	D=$t/$rel; mkdir -p "$D/kernel"
	(cd "$kb" && find . -name '*.ko' ! -path './source/*' -printf '%P\n') | while read -r m; do
		mkdir -p "$D/kernel/$(dirname "$m")"; cp "$kb/$m" "$D/kernel/$m"; done
	sed 's|^|kernel/|; s|\.o$|.ko|' "$kb/modules.order" > "$D/modules.order"
	sed 's|^|kernel/|' "$kb/modules.builtin" > "$D/modules.builtin"
	[ -f "$kb/modules.builtin.modinfo" ] && cp "$kb/modules.builtin.modinfo" "$D/"
	stage_tree "$D" "$rel" "$(basename "$kb") ($(git -C "$kb/source" rev-parse --short HEAD 2>/dev/null || echo '?'))"
	rm -rf "$t"
}

modules() {
	[ $# -gt 0 ] || { echo "usage: $0 modules MODULES.tar.gz|KBUILD_DIR ..."; exit 1; }
	local a
	for a in "$@"; do
		if [ -d "$a" ]; then modules_kbuild "$a"
		elif [ -f "$a" ]; then modules_tar "$a"
		else echo "modules: $a: no such file or directory"; exit 1; fi
	done
	echo "staged module trees: $(ls "$MODULES/lib/modules" | tr '\n' ' ')"
}

# Test-only inputs of the DEV mode and the initramfs: single files, mounted
# read only
in_file() {
	local name=$1 path=$2
	[ -n "$path" ] || return 0
	[ -f "$path" ] || { echo "$name=$path: no such file"; exit 1; }
	dargs+=(-v "$(readlink -f "$path"):/in/$name:ro" -e "$name=/in/$name")
}

initramfs() {
	need_binfmt
	local dargs
	dargs=(--rm --platform $PLATFORM -v "$REPO:/w" -e ALPINE="$ALPINE" -e UIDGID="$UIDGID")
	if [ -s "$AUTHORIZED_KEYS" ]; then dargs+=(-v "$(readlink -f "$AUTHORIZED_KEYS"):/in/authorized_keys:ro" -e AUTHORIZED_KEYS=/in/authorized_keys); fi
	in_file RTL8363_INIT "${RTL8363_INIT:-}"
	docker run "${dargs[@]}" "$IMAGE" /w/rootfs/initramfs/mkinitramfs.sh /w/rootfs/out/initramfs.cpio
}

# The apk tree: a required folder with <ALPINE>/common and <ALPINE>/uc-pxx. It
# becomes the read-only mount /aports in the container.
need_apk_tree() {
	[ -n "${TSX_APK_LOCAL:-}" ] || { echo "TSX_APK_LOCAL is required (a tsx-aports published tree with $ALPINE/common and $ALPINE/uc-pxx, see rootfs/fetch-apk-tree.sh)"; exit 1; }
	[ -d "$TSX_APK_LOCAL/$ALPINE" ] || { echo "TSX_APK_LOCAL=$TSX_APK_LOCAL has no $ALPINE/ (a tsx-aports published tree)"; exit 1; }
}

# The whole repository is /w in the container. So the builder uses the
# single sources outside rootfs/ directly.
rootfs() {
	need_apk_tree; need_binfmt
	local dargs
	dargs=(--rm --platform $PLATFORM -v "$REPO:/w" -e ALPINE="$ALPINE" -e UIDGID="$UIDGID" -e OUT=/w/rootfs/out)
	if [ -s "$AUTHORIZED_KEYS" ]; then dargs+=(-v "$(readlink -f "$AUTHORIZED_KEYS"):/in/authorized_keys:ro" -e AUTHORIZED_KEYS=/in/authorized_keys); fi
	[ -d "$MODULES" ] && dargs+=(-v "$MODULES:/modules:ro")
	dargs+=(-v "$(cd "$TSX_APK_LOCAL" && pwd):/aports:ro" -e TSX_APK_LOCAL=/aports)
	if [ "${UC_PXX_DEV_OVERLAY:-}" = 1 ]; then
		echo "WARNING: UC_PXX_DEV_OVERLAY=1: TEST BUILD without the uc-pxx packages. Never publish this image."
		[ -n "${UC_PXX_BOOTCTL:-}" ] || { echo "UC_PXX_DEV_OVERLAY=1 needs UC_PXX_BOOTCTL"; exit 1; }
		[ -n "${RTL8363_INIT:-}" ] || { echo "UC_PXX_DEV_OVERLAY=1 needs RTL8363_INIT"; exit 1; }
		dargs+=(-e UC_PXX_DEV_OVERLAY=1)
		in_file UC_PXX_BOOTCTL "$UC_PXX_BOOTCTL"
		in_file RTL8363_INIT "$RTL8363_INIT"
	fi
	mkdir -p "$HOME/.cache/uc-pxx-pip"
	docker run "${dargs[@]}" -v "$HOME/.cache/uc-pxx-pip:/build/pip" \
		-e KVER="$KVER" -e IMG_MB="${IMG_MB:-}" -e IMG_HEADROOM_MB="${IMG_HEADROOM_MB:-256}" \
		-e TSX_APK_URL="${TSX_APK_URL:-https://tsx-aports.unexceptional.net}" -e TSX_BUILD_ID="${TSX_BUILD_ID:-}" \
		-e PROFILE="${PROFILE:-ha}" -e TSX_DEV_ROOT_HASH="${TSX_DEV_ROOT_HASH:-}" \
		"$IMAGE" /w/rootfs/mkrootfs.sh
}

cmd=${1:-all}; [ $# -gt 0 ] && shift
case "$cmd" in
modules) modules "$@";;
initramfs) initramfs;;
rootfs|all) rootfs;;
*) echo "usage: $0 [modules FILE|DIR...|initramfs|rootfs|all]"; exit 1;;
esac
