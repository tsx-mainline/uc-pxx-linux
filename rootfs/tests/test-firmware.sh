#!/bin/sh
# Host test for uc-pxx-firmware with a made-up vendor folder (UC_PXX_FW_SRC)
# and a made-up sysfs (UC_PXX_SYSFS). It checks the file map, that an existing
# file stays, the status, the reload of regulatory.db and the new start of the
# Wi-Fi and Bluetooth drivers.
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
# The made-up sysfs: two Broadcom SDIO functions without a driver (the
# firmware was missing at the probe), one other SDIO device, and the
# Bluetooth serdev device on hci_uart_bcm.
S=$T/sys
for f in 1 2; do mkdir -p "$S/bus/sdio/devices/mmc1:0001:$f"; echo 0x02d0 > "$S/bus/sdio/devices/mmc1:0001:$f/vendor"; done
mkdir -p "$S/bus/sdio/devices/mmc2:0001:1"; echo 0x0271 > "$S/bus/sdio/devices/mmc2:0001:1/vendor"
mkdir -p "$S/bus/sdio/drivers/brcmfmac" "$S/bus/serial/devices/serial0-0" "$S/bus/serial/drivers/hci_uart_bcm" "$S/module/hci_uart"
: > "$S/bus/sdio/drivers/brcmfmac/bind"; : > "$S/bus/sdio/drivers/brcmfmac/unbind"
: > "$S/bus/serial/drivers/hci_uart_bcm/bind"; : > "$S/bus/serial/drivers/hci_uart_bcm/unbind"
: > "$S/bus/serial/devices/serial0-0/uevent"; : > "$S/module/hci_uart/uevent"
ln -s ../../devices/serial0-0 "$S/bus/serial/drivers/hci_uart_bcm/serial0-0"
ln -s ../../../module/hci_uart "$S/bus/serial/drivers/hci_uart_bcm/module"
printf '#!/bin/sh\necho "$*" >> "%s/iw.calls"\n' "$T" > "$T/iw"; chmod 755 "$T/iw"
: > "$T/dmesg"
fw() {
	env -i PATH="$PATH" UC_PXX_FW_SRC="$T/vendor" UC_PXX_FW_DEST="$T/dest" UC_PXX_RUN="$T" \
		UC_PXX_SYSFS="$S" UC_PXX_IW="$T/iw" UC_PXX_DMESG="cat $T/dmesg" UC_PXX_FW_WAIT=0 sh "$P" "$@"
}
has() { if printf '%s\n' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (no '$2' in the output)"; fi; }
hasnt() { if printf '%s\n' "$1" | grep -qF -- "$2"; then bad "$3 ('$2' in the output)"; else ok "$3"; fi; }

fw status | grep -c '^missing' | { read -r n; eq "$n" 3 "status: all three files are missing"; }
echo db > "$T/dest/regulatory.db"
out=$(fw boot 2>&1)
eq "$(cat "$T/dest/brcm/brcmfmac43456-sdio.bin")" wifi "the Wi-Fi firmware is copied"
eq "$(cat "$T/dest/brcm/brcmfmac43456-sdio.txt")" nvram "the NVRAM file is copied"
eq "$(cat "$T/dest/brcm/BCM4345C5.hcd")" bt "the Bluetooth patch is copied"
fw status | grep -c '^present' | { read -r n; eq "$n" 3 "status: all three files are present"; }

echo "== first boot: the drivers start again =="
eq "$(cat "$T/iw.calls")" "reg reload" "regulatory.db: iw reg reload"
has "$out" "loaded regulatory.db" "regulatory.db: logged"
has "$out" "Wi-Fi: bound mmc1:0001:1 to brcmfmac" "Wi-Fi: function 1 is bound"
has "$out" "Wi-Fi: bound mmc1:0001:2 to brcmfmac" "Wi-Fi: function 2 is bound"
eq "$(printf '%s\n' "$out" | grep -n 'bound mmc1' | cut -d: -f1 | tr '\n' ' ')" \
	"$(printf '%s\n' "$out" | grep -n 'bound mmc1:0001:1' | cut -d: -f1) $(printf '%s\n' "$out" | grep -n 'bound mmc1:0001:2' | cut -d: -f1) " \
	"Wi-Fi: function 1 before function 2"
eq "$(cat "$S/bus/sdio/drivers/brcmfmac/bind")" "mmc1:0001:2" "Wi-Fi: the last bind write is function 2"
hasnt "$out" "mmc2:0001:1" "Wi-Fi: another SDIO device stays alone"
has "$out" "no Wi-Fi interface after 0 s" "Wi-Fi: a missing interface is logged"
has "$out" "Bluetooth: started serial0-0 again (new patch file)" "Bluetooth: rebind after the copy"
eq "$(cat "$S/bus/serial/drivers/hci_uart_bcm/unbind")/$(cat "$S/bus/serial/drivers/hci_uart_bcm/bind")" \
	"serial0-0/serial0-0" "Bluetooth: unbind and bind of serial0-0"
hasnt "$out" "module" "Bluetooth: the module link is no device"
[ -e "$T/uc-pxx-firmware.copied" ] && bad "the list of copied files stays" || ok "the list of copied files is removed"

echo "== later boots =="
out=$(fw boot 2>&1)
has "$out" "Bluetooth: already started again in this boot" "Bluetooth: once per boot"
rm -f "$T/uc-pxx-firmware.bt-done"
echo "hci0: BCM: firmware Patch file not found, tried:" > "$T/dmesg"
out=$(fw boot 2>&1)
has "$out" "Bluetooth: started serial0-0 again (patch missed at the probe)" "Bluetooth: rebind when the kernel log shows a missed patch"
rm -f "$T/uc-pxx-firmware.bt-done"; : > "$T/dmesg"
out=$(fw boot 2>&1)
has "$out" "Bluetooth: the patch is loaded" "Bluetooth: no rebind when the patch was loaded"
[ -e "$T/uc-pxx-firmware.bt-done" ] && bad "Bluetooth: marker without a rebind" || ok "Bluetooth: no marker without a rebind"
rm -f "$T/uc-pxx-firmware.bt-done"
out=$(env -i PATH="$PATH" UC_PXX_FW_SRC="$T/vendor" UC_PXX_FW_DEST="$T/dest" UC_PXX_RUN="$T" \
	UC_PXX_SYSFS="$S" UC_PXX_IW="$T/iw" UC_PXX_DMESG=false UC_PXX_FW_WAIT=0 sh "$P" boot 2>&1)
has "$out" "(kernel log not readable)" "Bluetooth: rebind when the kernel log is not readable"
rm -f "$T/uc-pxx-firmware.bt-done"

echo "== Wi-Fi already running =="
for f in 1 2; do ln -s ../../../bus/sdio/drivers/brcmfmac "$S/bus/sdio/devices/mmc1:0001:$f/driver"
	ln -s ../../devices/mmc1:0001:$f "$S/bus/sdio/drivers/brcmfmac/mmc1:0001:$f"; done
mkdir -p "$S/bus/sdio/devices/mmc1:0001:2/net/wlan0"
: > "$S/bus/sdio/drivers/brcmfmac/bind"
out=$(fw boot 2>&1)
has "$out" "Wi-Fi: driver already running" "Wi-Fi: a running driver is left alone"
eq "$(cat "$S/bus/sdio/drivers/brcmfmac/bind")" "" "Wi-Fi: no bind write"
rm -f "$T/dest/brcm/brcmfmac43456-sdio.txt" "$T/uc-pxx-firmware.bt-done"
out=$(fw boot 2>&1)
eq "$(printf '%s\n' "$out" | sed -n 's/.*Wi-Fi: unbound \(mmc1:0001:[12]\).*/\1/p' | tr '\n' ' ')" \
	"mmc1:0001:2 mmc1:0001:1 " "Wi-Fi: new files unbind function 2, then function 1"

echo "== missing pieces =="
rm -f "$T/dest/regulatory.db" "$T/uc-pxx-firmware.bt-done"
out=$(fw boot 2>&1)
has "$out" "no regulatory.db" "regulatory.db: a missing file is logged"
out=$(env -i PATH="$PATH" UC_PXX_FW_SRC="$T/vendor" UC_PXX_FW_DEST="$T/dest" UC_PXX_RUN="$T" \
	UC_PXX_SYSFS="$T/nosys" UC_PXX_IW="$T/iw" UC_PXX_DMESG="cat $T/dmesg" UC_PXX_FW_WAIT=0 sh "$P" boot 2>&1)
has "$out" "Wi-Fi: no brcmfmac driver" "Wi-Fi: no driver is logged"
has "$out" "Bluetooth: no hci_uart_bcm driver" "Bluetooth: no driver is logged"
echo changed > "$T/vendor/etc/firmware/BCM4345C5.hcd"
fw boot 2>&1 | grep -q 'all firmware files are there' && ok "a second run copies nothing" || bad "a second run copies again"
eq "$(cat "$T/dest/brcm/BCM4345C5.hcd")" bt "an existing file stays"
rm -f "$T/dest/brcm/BCM4345C5.hcd" "$T/vendor/etc/firmware/BCM4345C5.hcd"
fw boot 2>&1 | grep -q 'no BCM4345C5.hcd' && ok "a missing vendor file is reported" || bad "no report for a missing vendor file"
fw bogus >/dev/null 2>&1; eq "$?" 2 "an unknown command exits 2"
echo "$N passed, $F failed"
[ "$F" = 0 ]
