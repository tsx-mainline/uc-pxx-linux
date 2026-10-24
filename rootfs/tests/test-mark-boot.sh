#!/bin/sh
# Host test for the boot-marking hook (rootfs/overlay/etc/uc-pxx-mark-boot.sh)
# and for uc-pxx-arm-slot. The scripts run from a copy whose fixed paths point
# into a temporary directory. They use the real uc-pxx-bootctl on a sector
# file, so this test needs a program that runs on the host:
#   UC_PXX_BOOTCTL_RUN="qemu-aarch64-static /path/uc-pxx-bootctl-aarch64" sh rootfs/tests/test-mark-boot.sh
# Without the variable it prints SKIPPED and exits 0. Needs python3 and flock.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
HOOK=$HERE/overlay/etc/uc-pxx-mark-boot.sh
ARM=$HERE/overlay/usr/sbin/uc-pxx-arm-slot
FLASH=$HERE/overlay/usr/sbin/uc-pxx-flash-boot
[ -n "${UC_PXX_BOOTCTL_RUN:-}" ] || { echo "SKIPPED: UC_PXX_BOOTCTL_RUN is not set"; exit 0; }
for t in python3 flock; do command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED: $t is not installed"; exit 0; }; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
mkdir -p "$T/run" "$T/etc" "$T/bin"

# the scripts with their fixed paths moved into $T
for s in HOOK ARM; do
	eval "src=\$$s"
	sed -e "s#/run/#$T/run/#g" -e "s#/etc/#$T/etc/#g" -e "s#/proc/cmdline#$T/cmdline#g" \
	    -e "s#/proc/uptime#$T/uptime#g" -e "s#/proc/sys/kernel/tainted#$T/tainted#g" \
	    -e "s#/dev/kmsg#$T/kmsg#g" -e "s#/sys/class/#$T/sys/#g" -e "s#/usr/sbin/uc-pxx-bootctl#$T/bin/uc-pxx-bootctl#g" \
	    -e 's/^NET_WAIT_SECS=300/NET_WAIT_SECS=0/' "$src" > "$T/$s.sh"
done
printf '#!/bin/sh\nexec %s "$@" --file %s/sector --boot-file %s/boot.img\n' "$UC_PXX_BOOTCTL_RUN" "$T" "$T" > "$T/bin/uc-pxx-bootctl"
printf '#!/bin/sh\necho "    inet 192.0.2.10/24"\n' > "$T/bin/ip"
printf '#!/bin/sh\n[ -e "%s/sshd-up" ]\n' "$T" > "$T/bin/pidof"
chmod 755 "$T"/bin/*
echo "100.00 100.00" > "$T/uptime"; echo 0 > "$T/tainted"

# sector A B: "prio,tries,succ" for each slot, valid CRC (big-endian)
mksector() {
	python3 -I - "$T/sector" "$1" "$2" <<'PY'
import binascii, sys
b = bytearray(512)
b[:4] = b"\0AB0"; b[4] = 1
b[8:11] = bytes(int(x) for x in sys.argv[2].split(","))
b[12:15] = bytes(int(x) for x in sys.argv[3].split(","))
b[28:32] = (binascii.crc32(bytes(b[:28])) & 0xffffffff).to_bytes(4, "big")
open(sys.argv[1], "wb").write(b)
PY
}
mkboot() {
	python3 -I - "$T/boot.img" "$1" <<'PY'
import sys
h = bytearray(4096); h[:8] = b"ANDROID!"; h[48:48 + len(sys.argv[2])] = sys.argv[2].encode()
open(sys.argv[1], "wb").write(h)
PY
}
# reset: A trying {15,7,0}, B successful {14,0,1}, boot_a token tok1, healthy system
reset() {
	mksector 15,7,0 14,0,1; mkboot tok1
	echo "console=ttyS2,115200n8 rdinit=/init uc-pxx.id=tok1" > "$T/cmdline"
	rm -f "$T/run/"* "$T/etc/uc-pxx-nomark" "$T/etc/uc-pxx-build-id"; : > "$T/sshd-up"
}
marked() { [ "$(od -An -tu1 -j8 -N3 "$T/sector" | tr -s ' ')" = " 15 0 1" ]; }
unchanged() { [ "$(od -An -tu1 -j8 -N3 "$T/sector" | tr -s ' ')" = " 15 7 0" ]; }
hook() { PATH="$T/bin:$PATH" sh "$T/HOOK.sh" >/dev/null 2>&1; }

echo "== the hook =="
reset; hook; rc=$?
{ [ $rc = 0 ] && marked; } && ok "a command line token that equals the boot_a header marks A" || bad "no mark with a matching token (rc $rc)"
reset; echo "console=ttyS2 uc-pxx.id=tok2" > "$T/cmdline"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "a command line token that differs from the header: no mark" || bad "marked with a wrong token (rc $rc)"
reset; echo "console=ttyS2 rdinit=/init" > "$T/cmdline"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "no token on the command line: no mark" || bad "marked without a token (rc $rc)"
reset; echo "console=ttyS2 rdinit=/init" > "$T/cmdline"; echo tok1 > "$T/etc/uc-pxx-build-id"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "a token only in the root file system: no mark" || bad "marked from a file of the root file system (rc $rc)"
grep -q 'build-id' "$HOOK" && grep -v '^#' "$HOOK" | grep -q 'build-id' && bad "the hook code reads a build-id file" || ok "the hook code has no build-id file"
reset; touch "$T/run/uc-pxx-slot-a-changed"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "the marker uc-pxx-slot-a-changed: no mark" || bad "marked with the marker present (rc $rc)"
reset; echo "uc-pxx.id=tok1 uc-pxx.nomark" > "$T/cmdline"; hook; rc=$?
{ [ $rc = 0 ] && unchanged; } && ok "uc-pxx.nomark: A left as it is" || bad "uc-pxx.nomark did not hold (rc $rc)"
reset; touch "$T/etc/uc-pxx-nomark"; hook; rc=$?
{ [ $rc = 0 ] && unchanged; } && ok "/etc/uc-pxx-nomark: A left as it is" || bad "/etc/uc-pxx-nomark did not hold (rc $rc)"
reset; rm -f "$T/sshd-up"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "no sshd: no mark" || bad "marked without sshd (rc $rc)"
reset; echo 128 > "$T/tainted"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "kernel oops (taint bit 7): no mark" || bad "marked after an oops (rc $rc)"
reset; ( flock -n 9 && sleep 5 ) 9> "$T/run/uc-pxx-abdata.lock" & sleep 1
hook; rc=$?; wait
{ [ $rc = 1 ] && unchanged; } && ok "lock held by another program: no mark" || bad "marked while the lock was held (rc $rc)"

echo "== uc-pxx-arm-slot =="
reset; mksector 15,0,1 14,0,1
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 0 ] && unchanged && [ -e "$T/run/uc-pxx-slot-a-changed" ]; } && ok "A successful becomes {15,7,0}, the marker exists" || bad "arm-slot failed (rc $rc)"
reset; mksector 15,0,1 14,3,0
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 1 ] && [ "$(od -An -tu1 -j8 -N8 "$T/sector" | tr -s ' ')" = " 15 0 1 0 14 3 0 0" ]; } && ok "B not successful: refused, sector unchanged" || bad "arm-slot with B trying (rc $rc)"
grep -q '/run/uc-pxx-slot-a-changed' "$FLASH" && ok "the flash wrapper sets the same marker" || bad "the flash wrapper has another marker"
reset; ( flock -n 9 && sleep 3 ) 9> "$T/run/uc-pxx-abdata.lock" & sleep 1
mksector 15,0,1 14,0,1
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?; wait
{ [ $rc = 0 ] && unchanged; } && ok "arm-slot waits for the lock, then arms" || bad "arm-slot did not wait for the lock (rc $rc)"
echo "$N ok, $F failed"
[ "$F" = 0 ]
