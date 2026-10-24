#!/bin/sh
# Host test for uc-pxx-firmware with a made-up vendor folder (UC_PXX_FW_SRC).
# It checks the file map, that an existing file stays, and the status.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
P=$HERE/overlay/usr/local/sbin/uc-pxx-firmware
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

busybox sh -n "$P" && ok "uc-pxx-firmware passes busybox sh -n" || bad "busybox sh -n"
mkdir -p "$T/vendor/etc/firmware" "$T/dest"
echo wifi > "$T/vendor/etc/firmware/fw_bcm43456c5_ag.bin"
echo nvram > "$T/vendor/etc/firmware/nvram_ap6256_FCC.txt"
echo bt > "$T/vendor/etc/firmware/BCM4345C5.hcd"
fw() { env -i PATH="$PATH" UC_PXX_FW_SRC="$T/vendor" UC_PXX_FW_DEST="$T/dest" UC_PXX_RUN="$T" sh "$P" "$@"; }

fw status | grep -c '^missing' | { read -r n; eq "$n" 3 "status: all three files are missing"; }
fw boot >/dev/null 2>&1
eq "$(cat "$T/dest/brcm/brcmfmac43456-sdio.bin")" wifi "the Wi-Fi firmware is copied"
eq "$(cat "$T/dest/brcm/brcmfmac43456-sdio.txt")" nvram "the NVRAM file is copied"
eq "$(cat "$T/dest/brcm/BCM4345C5.hcd")" bt "the Bluetooth patch is copied"
fw status | grep -c '^present' | { read -r n; eq "$n" 3 "status: all three files are present"; }
echo changed > "$T/vendor/etc/firmware/BCM4345C5.hcd"
fw boot 2>&1 | grep -q 'all firmware files are there' && ok "a second run copies nothing" || bad "a second run copies again"
eq "$(cat "$T/dest/brcm/BCM4345C5.hcd")" bt "an existing file stays"
rm -f "$T/dest/brcm/BCM4345C5.hcd" "$T/vendor/etc/firmware/BCM4345C5.hcd"
fw boot 2>&1 | grep -q 'no BCM4345C5.hcd' && ok "a missing vendor file is reported" || bad "no report for a missing vendor file"
fw bogus >/dev/null 2>&1; eq "$?" 2 "an unknown command exits 2"
echo "$N passed, $F failed"
[ "$F" = 0 ]
