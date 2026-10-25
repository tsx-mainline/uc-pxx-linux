#!/bin/sh
# Host test for uc-pxx-install-rootfs (rootfs/initramfs/overlay/usr/sbin). It
# needs no panel: a made-up /sys, a made-up /dev with plain files for the
# partitions, and a made-up uc-pxx-bootctl. It needs mkfs.ext4, e2fsck,
# resize2fs, blkid and busybox. Without them it prints SKIPPED.
#   - the refusals (name, size, eMMC, mounted, A/B state), each before a write
#   - a write from a file and from standard input, read back and checked
#   - only system_a changes: boot_a and misc stay byte for byte the same
#   - a wrong sha256, a wrong --size, a label that is not tsxroot
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
IR=$HERE/initramfs/overlay/usr/sbin/uc-pxx-install-rootfs
for t in mkfs.ext4 e2fsck resize2fs blkid busybox; do
	command -v $t > /dev/null || { echo "SKIPPED: no $t"; exit 0; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
SECT=8192   # 4 MiB stands in for the 1792 MiB of system_a

S=$T/sys/class/block; D=$T/dev; mkdir -p "$D" "$T/run" "$T/tmp"
mkpart() { # NAME PARTNAME
	mkdir -p "$S/$1"; echo "PARTNAME=$2" > "$S/$1/uevent"; echo "$SECT" > "$S/$1/size"
	dd if=/dev/urandom of="$D/$1" bs=512 count=$SECT status=none
}
mkdir -p "$S/mmcblk0/device"; echo MMC > "$S/mmcblk0/device/type"
mkpart mmcblk0p5 misc; mkpart mmcblk0p13 boot_a; mkpart mmcblk0p22 system_a
: > "$T/mounts"
bc() { # A_PRIO A_TRIES A_SUCC B_PRIO B_TRIES B_SUCC
	printf '#!/bin/sh\necho "uc-pxx-bootctl: current: A{prio %s tries %s succ %s} B{prio %s tries %s succ %s} crc 1" >&2\necho "libavb-would-boot: a"\n' "$@" > "$T/bootctl"
	chmod 755 "$T/bootctl"
}
bc 15 7 0 14 0 1
export TSX_SYSBLOCK=$S TSX_DEVDIR=$D TSX_BOOTCTL=$T/bootctl TSX_MOUNTS=$T/mounts TSX_RUN=$T/run TSX_TMP=$T/tmp TSX_SYSTEM_A_SECTORS=$SECT TSX_HB_S=1
run() { busybox sh "$IR" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
sum() { sha256sum "$D/$1" | cut -d' ' -f1; }

mkfs.ext4 -q -F -L tsxroot -O ^has_journal "$T/good.img" 3M
SHA=$(sha256sum "$T/good.img" | cut -d' ' -f1)
SIZE=$(wc -c < "$T/good.img")
mkfs.ext4 -q -F -L other -O ^has_journal "$T/other.img" 3M
SHA_O=$(sha256sum "$T/other.img" | cut -d' ' -f1)
BOOT0=$(sum mmcblk0p13) MISC0=$(sum mmcblk0p5) SYS0=$(sum mmcblk0p22)

echo "== syntax and --help =="
busybox sh -n "$IR" && ok "busybox sh -n" || bad "busybox sh -n"
run --help; grep -q 'never writes boot_a' "$T/out" && ok "--help says boot_a is not written" || bad "--help"

echo "== preflight --check writes nothing =="
run --check
[ "$(rc)" = 0 ] && ok "--check passes" || bad "--check: $(cat "$T/out")"
grep -q 'slot B       : priority 14, tries 0, successful 1' "$T/out" && ok "the A/B state is shown" || bad "no A/B state in the output"
[ "$(sum mmcblk0p22)" = "$SYS0" ] && ok "system_a is unchanged" || bad "--check wrote system_a"

echo "== refusals (each before any write) =="
refuse() { # WHAT PATTERN ARGS...
	w=$1 p=$2; shift 2
	run "$@"
	if [ "$(rc)" != 0 ] && grep -q -- "$p" "$T/out"; then ok "refused: $w"; else bad "not refused: $w ($(tail -n 1 "$T/out"))"; fi
	[ "$(sum mmcblk0p22)" = "$SYS0" ] && [ "$(sum mmcblk0p13)" = "$BOOT0" ] && [ "$(sum mmcblk0p5)" = "$MISC0" ] || bad "a refusal changed a partition ($w)"
}
refuse "a bad sha256 argument" "usage\|uc-pxx-install-rootfs" notasha "$T/good.img"
refuse "an image that is too large" "larger than" --size $((SECT * 512 + 1)) "$SHA"
bc 15 7 0 14 0 0; refuse "slot B not successful" "no fallback" "$SHA" "$T/good.img"
bc 15 7 0 15 0 1; refuse "slot B priority 15" "no fallback" "$SHA" "$T/good.img"
bc 15 7 0 14 3 1; refuse "slot B with tries left" "no fallback" "$SHA" "$T/good.img"
printf '#!/bin/sh\necho "uc-pxx-bootctl: refusing: x" >&2\nexit 1\n' > "$T/bootctl"; refuse "bootctl status fails" "status failed" "$SHA" "$T/good.img"
bc 15 7 0 14 0 1
echo "$D/mmcblk0p22 /mnt ext4 rw 0 0" > "$T/mounts"; refuse "system_a mounted" "is mounted" "$SHA" "$T/good.img"
: > "$T/mounts"
echo SD > "$S/mmcblk0/device/type"; refuse "not an eMMC" "not an eMMC" "$SHA" "$T/good.img"
echo MMC > "$S/mmcblk0/device/type"
echo 8000 > "$S/mmcblk0p22/size"; refuse "a size that is not the layout" "expected" "$SHA" "$T/good.img"
echo $SECT > "$S/mmcblk0p22/size"
echo "PARTNAME=system_b" > "$S/mmcblk0p22/uevent"; refuse "no partition named system_a" "no partition" "$SHA" "$T/good.img"
echo "PARTNAME=system_a" > "$S/mmcblk0p22/uevent"
mv "$S/mmcblk0p22" "$S/mmcblk0p21"; refuse "system_a on another partition number" "not mmcblk0p22" "$SHA" "$T/good.img"
mv "$S/mmcblk0p21" "$S/mmcblk0p22"

echo "== a write from a file =="
run "$SHA" "$T/good.img"
[ "$(rc)" = 0 ] && ok "exit 0" || bad "exit $(rc): $(tail -n 3 "$T/out")"
grep -q 'sha256 matches' "$T/out" && ok "the read-back matched" || bad "no read-back line"
grep -q 'verified (ext4, label tsxroot)' "$T/out" && ok "the label was checked" || bad "no label line"
grep -q 'MiB' "$T/out" && grep -q '100%' "$T/out" && ok "the output shows MiB and percent" || bad "no progress in the output"
[ "$(sum mmcblk0p13)" = "$BOOT0" ] && ok "boot_a is unchanged" || bad "boot_a changed"
[ "$(sum mmcblk0p5)" = "$MISC0" ] && ok "misc is unchanged" || bad "misc changed"
[ "$(sum mmcblk0p22)" != "$SYS0" ] && ok "system_a changed" || bad "system_a did not change"
blkid "$D/mmcblk0p22" | grep -q 'LABEL="tsxroot"' && ok "system_a has the label tsxroot" || bad "no label on system_a"
dumpe2fs -h "$D/mmcblk0p22" 2>/dev/null | grep -q 'Block count: *4096' && ok "the file system fills system_a (4 MiB)" || bad "the file system was not grown"

echo "== a write from standard input =="
dd if=/dev/urandom of="$D/mmcblk0p22" bs=512 count=$SECT status=none
busybox sh "$IR" --size "$SIZE" "$SHA" < "$T/good.img" > "$T/out" 2>&1; echo $? > "$T/rc"
[ "$(rc)" = 0 ] && ok "stdin with --size: exit 0" || bad "stdin: exit $(rc): $(tail -n 3 "$T/out")"
grep -q 'sha256 matches' "$T/out" && ok "stdin: read-back matched" || bad "stdin: no read-back"
[ -s "$T/run/tsx-op" ] && bad "the rescue state file was written on a host" || ok "no rescue state files on a host"

echo "== a stream that is cut short, a wrong sha256, a wrong label =="
head -c $((SIZE - 100000)) "$T/good.img" > "$T/short.img"
busybox sh "$IR" --size "$SIZE" "$SHA" < "$T/short.img" > "$T/out" 2>&1; echo $? > "$T/rc"
[ "$(rc)" != 0 ] && grep -q 'cut short' "$T/out" && ok "a short stream is refused" || bad "a short stream was accepted"
WRONG=$(printf x | sha256sum | cut -d' ' -f1)
run "$WRONG" "$T/good.img"
[ "$(rc)" != 0 ] && grep -q 'expected' "$T/out" && ok "a wrong sha256 fails" || bad "a wrong sha256 passed"
run "$SHA_O" "$T/other.img"
[ "$(rc)" != 0 ] && grep -q 'no ext4 label tsxroot' "$T/out" && ok "a label that is not tsxroot fails" || bad "a wrong label passed"
[ "$(sum mmcblk0p13)" = "$BOOT0" ] && [ "$(sum mmcblk0p5)" = "$MISC0" ] && ok "boot_a and misc are still unchanged" || bad "boot_a or misc changed"

echo "== the rescue state files =="
touch "$T/run/tsx-rescue-login"
run --check
grep -q '^done: preflight OK' "$T/run/tsx-install-state" && ok "the rescue screen gets the state" || bad "no state file: $(cat "$T/run/tsx-install-state" 2>/dev/null)"

echo "$N passed, $F failed"
[ "$F" = 0 ]
