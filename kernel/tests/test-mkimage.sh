#!/bin/sh
# Host test for kernel/mkimage.sh with a made-up kernel Image and device
# tree. It checks the image layout, the build token and the refusals. It
# needs the cross compiler, mkbootimg, dtc and python3. When one is missing,
# it prints SKIPPED and exits 0.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
for t in "${CROSS}gcc" "${CROSS}ld" "${CROSS}objcopy" mkbootimg fdtget dtc python3; do
	command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED: $t is not installed"; exit 0; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

cat > "$T/good.dts" <<'DTS'
/dts-v1/;
/ { #address-cells = <2>; #size-cells = <2>; chosen { bootargs = "console=ttyS2,115200n8 rdinit=/init"; }; };
DTS
cat > "$T/noargs.dts" <<'DTS'
/dts-v1/;
/ { #address-cells = <2>; #size-cells = <2>; chosen { }; };
DTS
dtc -I dts -O dtb -o "$T/good.dtb" "$T/good.dts" 2>/dev/null
dtc -I dts -O dtb -o "$T/noargs.dtb" "$T/noargs.dts" 2>/dev/null
# an arm64 Image header: image_size at byte 16, the magic "ARM\x64" at byte 56
python3 -I - "$T/Image" <<'PY'
import struct, sys
n = 3 * 1024 * 1024
h = bytearray(n)
struct.pack_into("<Q", h, 16, n)
h[56:60] = b"ARMd"
open(sys.argv[1], "wb").write(h)
PY
printf 'device tree for u-boot' > "$T/uboot.dtb"
python3 -I "$HERE/mkresource.py" "$T/res.img" rk-kernel.dtb="$T/uboot.dtb" >/dev/null

echo "== a good image =="
if bash "$HERE/mkimage.sh" --resource "$T/res.img" --board test-build-1 "$T/Image" "$T/good.dtb" "$T/boot.img" > "$T/log" 2>&1; then
	ok "mkimage.sh runs"
else
	bad "mkimage.sh failed"; cat "$T/log"
fi
grep -q 'linux payload verified' "$T/log" && ok "the Linux Image is in the file" || bad "no payload check"
[ "$(head -c 8 "$T/boot.img")" = 'ANDROID!' ] && ok "Android boot image magic" || bad "no boot image magic"
tok=$(dd if="$T/boot.img" bs=1 skip=48 count=16 2>/dev/null | tr -d '\0')
[ "$tok" = test-build-1 ] && ok "the board field holds the build token" || bad "board field is '$tok'"
# the Image starts at page size + 2 MiB
cmp -s "$T/Image" "$T/boot.img" -i 0:$((2048 + 2097152)) -n 3145728 && ok "the Image is at 2 MiB behind the first page" || bad "wrong Image offset"

echo "== refusals =="
bash "$HERE/mkimage.sh" --board x "$T/Image" "$T/good.dtb" "$T/o" >/dev/null 2>&1 && bad "no --resource must fail" || ok "no --resource: error"
bash "$HERE/mkimage.sh" --resource "$T/res.img" --board 0123456789abcdef "$T/Image" "$T/good.dtb" "$T/o" >/dev/null 2>&1 && bad "a 16 character token must fail" || ok "a token of 16 characters: error"
bash "$HERE/mkimage.sh" --resource "$T/res.img" --board x "$T/Image" "$T/noargs.dtb" "$T/o" >/dev/null 2>&1 && bad "a device tree without bootargs must fail" || ok "no /chosen/bootargs: error"
bash "$HERE/mkimage.sh" --resource "$T/res.img" --board x --dest 0x4100000 "$T/Image" "$T/good.dtb" "$T/o" >/dev/null 2>&1 && bad "an unaligned --dest must fail" || ok "unaligned --dest: error"
UC_PXX_MAX_IMAGE=1000000 bash "$HERE/mkimage.sh" --resource "$T/res.img" --board x "$T/Image" "$T/good.dtb" "$T/o" >/dev/null 2>&1 && bad "an image over the limit must fail" || ok "an image over the size limit: error"
[ ! -e "$T/o" ] && ok "a refused build leaves no output file" || bad "a refused build wrote a file"
echo "$N ok, $F failed"
[ "$F" = 0 ]
