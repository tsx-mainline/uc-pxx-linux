#!/bin/bash
# Host test for rootfs/check-kernel-pins.sh. No kernel build and no docker. It
# uses fake boot images (a "Linux version" line in plain text) in a fake
# rootfs tree.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHECK=$HERE/check-kernel-pins.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

LTS_REV=a69f8a5c2a73da29c339bacf4367974eda52f9dd
mkdir -p "$W/pins"
printf '# lts\n%s\n' "$LTS_REV" > "$W/pins/KERNEL_REV.lts"

fakeroot() {   # DIR IMAGE_RELEASE FILE_RELEASE
	local d=$1
	rm -rf "$d"; mkdir -p "$d/boot" "$d/usr/share/uc-pxx"
	{ head -c 4096 /dev/zero; printf 'junk Linux version %s (builder@host) #1 SMP\n' "$2"; head -c 4096 /dev/zero; } > "$d/boot/uc-pxx-lts.img"
	echo "$3" > "$d/usr/share/uc-pxx/kernel-lts.release"
}
GOOD=6.18.54-00084-ga69f8a5c2a73
run() { "$CHECK" "$W/root" "$W/pins" >"$W/out.txt" 2>&1; }

echo "== 1. the image matches the pin"
fakeroot "$W/root" $GOOD $GOOD
run && ok "accepted" || bad "refused a good rootfs: $(cat "$W/out.txt")"
grep -q "lts $GOOD matches" "$W/out.txt" && ok "reported" || bad "report: $(cat "$W/out.txt")"

echo "== 2. stale image"
fakeroot "$W/root" 6.18.54-00067-g28576e06f794 6.18.54-00067-g28576e06f794
run && bad "accepted a stale image" || ok "refused"
grep -q "the boot image has kernel 6.18.54-00067-g28576e06f794" "$W/out.txt" && ok "message names the kernel" || bad "message: $(cat "$W/out.txt")"

echo "== 3. image good, release file stale"
fakeroot "$W/root" $GOOD 6.18.54-00067-g28576e06f794
run && bad "accepted a stale release file" || ok "refused"

echo "== 4. no module tree is fine, a tree of another release is not"
fakeroot "$W/root" $GOOD $GOOD
run && ok "no /lib/modules: accepted" || bad "refused a rootfs without modules"
mkdir -p "$W/root/lib/modules/6.18.54-other"
run && bad "accepted modules of another release" || ok "modules of another release: refused"
mkdir -p "$W/root/lib/modules/$GOOD"
run && ok "a tree of the right release: accepted" || bad "refused the right module tree"

echo "== 5. no image, and the placeholder pin"
fakeroot "$W/root" $GOOD $GOOD; rm "$W/root/boot/uc-pxx-lts.img"
run && bad "accepted a rootfs without a boot image" || ok "no boot image: refused"
printf '# lts\n0000000000000000000000000000000000000000\n' > "$W/pins/KERNEL_REV.lts"
fakeroot "$W/root" $GOOD $GOOD
run && bad "accepted a placeholder pin" || ok "placeholder pin: refused (the release does not match)"

echo "$N passed, $F failed"
[ "$F" = 0 ]
