#!/bin/sh
# Host test for the device tree code of the shim (bootloader/shim.S): the copy
# of /chosen/bootargs of the U-Boot device tree into /chosen/u-boot,bootargs of
# our device tree. It assembles only that code (UC_PXX_SHIM_FDT_TEST), links it
# with a small C program and runs it under qemu-aarch64. It needs the cross
# compiler, qemu-aarch64-static, dtc, fdtget and python3. When one is missing,
# it prints SKIPPED and exits 0. Run it on a build host.
#
# Optional real device trees (never commit them): UC_PXX_TEST_DTB (our device
# tree, for example rk3399-crestron-ucp10.dtb) and UC_PXX_TEST_UBOOT_DTB (a
# device tree that U-Boot passed in x0).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/.." && pwd)
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
QEMU=${QEMU:-qemu-aarch64-static}
for t in "${CROSS}gcc" "$QEMU" dtc fdtget python3; do
	command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED: $t is not installed"; exit 0; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

# run DST SRC|- ROOM OUT: prints the status of keep_uboot_args, writes our tree to OUT
cat > "$T/run.c" <<'C'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern uint64_t keep_uboot_args(void *dst, const void *src, void *end);
static void *load(const char *p, size_t room)
{
	FILE *f = fopen(p, "rb");
	void *b = aligned_alloc(64, room);
	if (!f || !b) { perror(p); exit(9); }
	memset(b, 0xa5, room);
	size_t n = fread(b, 1, room, f);
	if (n == room) { fprintf(stderr, "%s is too big\n", p); exit(9); }
	fclose(f);
	return b;
}
int main(int argc, char **argv)
{
	if (argc != 5) return 9;
	size_t room = strtoul(argv[3], NULL, 0);
	/* the room after the file is 0xa5, not zero: the code must not rely on zeros */
	uint8_t *dst = load(argv[1], room + 64);
	const void *src = strcmp(argv[2], "-") ? load(argv[2], 1 << 21) : NULL;
	uint64_t st = keep_uboot_args(dst, src, dst + room);
	uint32_t ts = __builtin_bswap32(*(uint32_t *)(dst + 4));
	if (dst[room] != 0xa5) { fprintf(stderr, "wrote past the room\n"); return 8; }
	FILE *o = fopen(argv[4], "wb");
	fwrite(dst, 1, ts, o);
	fclose(o);
	printf("%llu\n", (unsigned long long)st);
	return 0;
}
C
"${CROSS}gcc" -c -DUC_PXX_SHIM_FDT_TEST -o "$T/fdt.o" "$REPO/bootloader/shim.S" || { echo "FAIL: shim.S does not assemble"; exit 1; }
"${CROSS}gcc" -O2 -Wall -static -o "$T/run" "$T/run.c" "$T/fdt.o" || { echo "FAIL: the test program does not link"; exit 1; }
run() { "$QEMU" "$T/run" "$@"; }
dtb() { dtc -q -I dts -O dtb -o "$1" -; }
# norm DTB: the sorted source without the new property
norm() { dtc -q -s -I dtb -O dts "$1" | grep -v 'u-boot,bootargs'; }

# our tree: properties and subnodes around /chosen, a reservation, a node named chosen deeper down
dtb "$T/ours.dtb" <<'DTS'
/dts-v1/;
/memreserve/ 0x8000000 0x100000;
/ {
	#address-cells = <2>; #size-cells = <2>; model = "test";
	aliases { serial2 = "/serial@ff1a0000"; };
	bus { other { chosen { bootargs = "not this one"; }; }; };
	chosen {
		stdout-path = "serial2:115200n8";
		bootargs = "console=ttyS2,115200n8 rdinit=/init uc-pxx.id=ucpxx-test";
		sub { x = <1>; };
	};
	memory@200000 { device_type = "memory"; reg = <0 0x200000 0 0x8200000>; };
};
DTS
UBA='storagemedia=emmc androidboot.mode=normal androidboot.verifiedbootstate=orange androidboot.slot_suffix=_a androidboot.serialno=TEST0001'
ub() {
	dtb "$1" <<DTS
/dts-v1/;
/memreserve/ 0xe9dba000 0x1b000;
/ {
	#address-cells = <2>; #size-cells = <2>; serial-number = "TEST0001";
	firmware { android { compatible = "android,firmware"; }; };
	chosen { linux,initrd-start = <0 0xe9dd8000>; linux,initrd-end = <0 0xe9dd8014>; bootargs = "$2"; };
	memory { device_type = "memory"; reg = <0 0x200000 0 0x8200000>; };
};
DTS
}
ub "$T/uboot.dtb" "$UBA"

echo "== a copy =="
eq "$(run "$T/ours.dtb" "$T/uboot.dtb" 0x10000 "$T/out.dtb")" 0 "status 0"
eq "$(fdtget "$T/out.dtb" /chosen u-boot,bootargs 2>&1)" "$UBA" "/chosen/u-boot,bootargs is the U-Boot command line"
eq "$(fdtget "$T/out.dtb" /chosen bootargs)" "console=ttyS2,115200n8 rdinit=/init uc-pxx.id=ucpxx-test" "/chosen/bootargs stays our command line"
if [ "$(norm "$T/out.dtb")" = "$(norm "$T/ours.dtb")" ]; then ok "nothing else changed (dtc -s)"; else bad "the tree changed"; fi
dtc -q -I dtb -O dtb -o /dev/null "$T/out.dtb" 2>/dev/null && ok "dtc reads the result" || bad "dtc cannot read the result"
python3 -I - "$T/out.dtb" <<'PY' && ok "the header: blocks in order and inside totalsize" || bad "bad header"
import struct, sys
d = open(sys.argv[1], "rb").read()
m, tot, ost, ostr, orsv, ver, lcv, cpu, sstr, sst = struct.unpack(">10I", d[:40])
assert m == 0xd00dfeed and tot == len(d) and orsv < ost and ost + sst <= ostr and ostr + sstr <= tot
PY
eq "$(fdtget "$T/out.dtb" /bus/other/chosen bootargs)" "not this one" "the deeper node named chosen is not touched"
eq "$(fdtget "$T/out.dtb" /chosen/sub x)" 1 "a subnode of /chosen stays"
eq "$(run "$T/out.dtb" "$T/uboot.dtb" 0x10000 "$T/out2.dtb")" 5 "a second copy: status 5 (already there)"
cmp -s "$T/out.dtb" "$T/out2.dtb" && ok "and the tree is not changed" || bad "the tree changed on status 5"

echo "== every padding length =="
s=a
for i in 1 2 3 4 5 6 7 8; do
	ub "$T/u$i.dtb" "$s"
	st=$(run "$T/ours.dtb" "$T/u$i.dtb" 0x10000 "$T/o$i.dtb")
	[ "$st" = 0 ] && [ "$(fdtget "$T/o$i.dtb" /chosen u-boot,bootargs)" = "$s" ] &&
		[ "$(norm "$T/o$i.dtb")" = "$(norm "$T/ours.dtb")" ] || { bad "a string of $i bytes (status $st)"; s=${s}b; continue; }
	ok "a string of $i bytes"
	s=${s}b
done

echo "== nothing to copy: our tree stays the same =="
same() { cmp -s "$T/ours.dtb" "$1" && ok "$2: the tree is not changed" || bad "$2: the tree changed"; }
eq "$(run "$T/ours.dtb" - 0x10000 "$T/o.dtb")" 1 "no U-Boot tree (x0 = 0, a fastboot boot): status 1"; same "$T/o.dtb" "x0 = 0"
head -c 4096 /dev/urandom > "$T/junk.bin"
eq "$(run "$T/ours.dtb" "$T/junk.bin" 0x10000 "$T/o.dtb")" 1 "random bytes: status 1"; same "$T/o.dtb" "random bytes"
dtb "$T/noargs.dtb" <<'DTS'
/dts-v1/;
/ { chosen { stdout-path = "x"; }; bus { chosen { bootargs = "deep"; }; }; };
DTS
eq "$(run "$T/ours.dtb" "$T/noargs.dtb" 0x10000 "$T/o.dtb")" 2 "U-Boot /chosen without bootargs: status 2"; same "$T/o.dtb" "no bootargs"
dtb "$T/nochosen.dtb" <<'DTS'
/dts-v1/;
/ { model = "x"; };
DTS
eq "$(run "$T/ours.dtb" "$T/nochosen.dtb" 0x10000 "$T/o.dtb")" 2 "U-Boot tree without /chosen: status 2"; same "$T/o.dtb" "no /chosen"
dtb "$T/notstr.dtb" <<'DTS'
/dts-v1/;
/ { chosen { bootargs = <0x41414141>; }; };
DTS
eq "$(run "$T/ours.dtb" "$T/notstr.dtb" 0x10000 "$T/o.dtb")" 2 "bootargs without a NUL at the end: status 2"; same "$T/o.dtb" "not a string"
ub "$T/long.dtb" "$(head -c 5000 /dev/zero | tr '\0' x)"
eq "$(run "$T/ours.dtb" "$T/long.dtb" 0x10000 "$T/o.dtb")" 4 "a command line of 5000 bytes: status 4"; same "$T/o.dtb" "too long"
sz=$(stat -c %s "$T/ours.dtb")
eq "$(run "$T/ours.dtb" "$T/uboot.dtb" $((sz + 32)) "$T/o.dtb")" 4 "no room after our tree: status 4"; same "$T/o.dtb" "no room"
need=$(( sz + 12 + ( (${#UBA} + 1 + 3) / 4 * 4 ) + 16 ))
eq "$(run "$T/ours.dtb" "$T/uboot.dtb" $need "$T/o.dtb")" 0 "exactly enough room: status 0"
eq "$(run "$T/ours.dtb" "$T/uboot.dtb" $((need - 1)) "$T/o.dtb")" 4 "one byte less: status 4"
dtb "$T/oursnochosen.dtb" <<'DTS'
/dts-v1/;
/ { model = "x"; };
DTS
eq "$(run "$T/oursnochosen.dtb" "$T/uboot.dtb" 0x10000 "$T/o.dtb")" 3 "our tree without /chosen: status 3"

echo "== the real device trees (optional) =="
if [ -r "${UC_PXX_TEST_DTB:-}" ] && [ -r "${UC_PXX_TEST_UBOOT_DTB:-}" ]; then
	eq "$(run "$UC_PXX_TEST_DTB" "$UC_PXX_TEST_UBOOT_DTB" 0x1f0000 "$T/real.dtb")" 0 "the real trees: status 0"
	eq "$(fdtget "$T/real.dtb" /chosen u-boot,bootargs)" "$(fdtget "$UC_PXX_TEST_UBOOT_DTB" /chosen bootargs)" "the real U-Boot command line is copied"
	if [ "$(norm "$T/real.dtb")" = "$(norm "$UC_PXX_TEST_DTB")" ]; then ok "the real tree: nothing else changed"; else bad "the real tree changed"; fi
else
	echo "  (UC_PXX_TEST_DTB and UC_PXX_TEST_UBOOT_DTB are not set: skipped)"
fi
echo "$N ok, $F failed"
[ "$F" = 0 ]
