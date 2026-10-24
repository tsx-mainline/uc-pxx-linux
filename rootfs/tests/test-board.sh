#!/bin/sh
# Host test for the board file (rootfs/overlay/usr/local/lib/tsx/board.sh).
# It needs no panel and no compiler.
#   - the values of the board, and that a value from the environment wins
#   - sourcing the file prints nothing
#   - the functions, with a made-up cfg partition and device tree
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
BOARD=$HERE/overlay/usr/local/lib/tsx/board.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
# sh_run VAR=value...: run SH_CODE in a clean shell that has sourced the board file
sh_run() { env -i PATH="$PATH" "$@" sh -c ". '$BOARD'; $SH_CODE"; }

echo "== syntax =="
busybox sh -n "$BOARD" 2>/dev/null && ok "board.sh passes busybox sh -n" || bad "board.sh: busybox sh -n"

echo "== sourcing prints nothing and the values are the board values =="
out=$(env -i PATH="$PATH" sh -c ". '$BOARD'" 2>&1); eq "$out" "" "no output when sourced"
for kv in TSX_FAMILY=uc-pxx TSX_PKG_PREFIX=uc-pxx TSX_APK_CATEGORY=uc-pxx TSX_HA_MODEL=UC-P10 TSX_SOUND_CARD=UCP10 \
	TSX_DISPLAY_DRM=rockchip TSX_RENDER_DRM=panfrost TSX_DISPLAY_ENV= TSX_BT_CHIP=none \
	TSX_BT_MAC_SETTABLE=no TSX_MAC_SOURCE=cfg TSX_SERIAL_CONSOLE=ttyS2 \
	'TSX_VOLUME_CMD=uc-pxx-audio volume' 'TSX_VOLUME_FIXED_CMD=uc-pxx-audio fixed'; do
	k=${kv%%=*}; v=${kv#*=}
	SH_CODE="printf '%s' \"\$$k\""; eq "$(sh_run)" "$v" "$k"
done
SH_CODE='printf "%s/%s" "$TSX_SOUND_CARD" "$TSX_BT_CHIP"'
eq "$(sh_run TSX_SOUND_CARD=OTHER TSX_BT_CHIP=/x)" "OTHER//x" "a value in the environment wins"

echo "== the MAC address from the cfg partition (bytes 6 to 11) =="
# cfg: 1 MiB of zeros, with the MAC at byte 6
mkcfg() {
	dd if=/dev/zero of="$1" bs=1k count=1024 status=none
	[ -n "${2:-}" ] && printf "$2" | dd of="$1" bs=1 seek=6 conv=notrunc status=none
	return 0
}
mkcfg "$T/cfg" '\000\020\177\001\002\003'
mkcfg "$T/cfg-zero"
mkcfg "$T/cfg-mc" '\001\020\177\001\002\003'
mkcfg "$T/cfg-local" '\002\020\177\001\002\003'
SH_CODE='echo "mac=$(tsx_board_mac) unit=$(tsx_board_unit_id) src=$(tsx_board_mac_source)"'
eq "$(sh_run TSX_CFG="$T/cfg")" "mac=00:10:7f:01:02:03 unit=00107f010203 src=cfg" "MAC, unit id and source"
eq "$(sh_run TSX_CFG="$T/cfg-zero")" "mac= unit=unknown src=cfg" "an empty cfg: unit id unknown"
eq "$(sh_run TSX_CFG="$T/cfg-mc")" "mac= unit=unknown src=cfg" "a multicast MAC is not used"
eq "$(sh_run TSX_CFG="$T/cfg-local")" "mac= unit=unknown src=cfg" "a locally administered MAC is not used"
eq "$(sh_run TSX_CFG="$T/none")" "mac= unit=unknown src=cfg" "no cfg partition: nothing"
SH_CODE='tsx_board_mac_early'
eq "$(sh_run TSX_CFG="$T/cfg")" "00:10:7f:01:02:03" "tsx_board_mac_early reads the same bytes"
# the function reads six bytes and no more
grep -q 'count=6' "$BOARD" && ok "the read is limited to count=6" || bad "the read is not limited to six bytes"
grep -Eq 'of=|cp |cat .*cfg' "$BOARD" && bad "board.sh may copy the cfg partition" || ok "board.sh never copies the cfg partition"
# the partition is found by its name
mkdir -p "$T/sys/mmcblk0p3" "$T/dev"
echo 'PARTNAME=cfg' > "$T/sys/mmcblk0p3/uevent"
cp "$T/cfg" "$T/dev/mmcblk0p3"
SH_CODE='tsx_board_mac'
eq "$(sh_run TSX_SYSBLOCK="$T/sys" TSX_DEVDIR="$T/dev")" "00:10:7f:01:02:03" "the cfg partition is found by PARTNAME"

echo "== the model from the device tree compatible =="
printf 'crestron,uc-p10\0rockchip,rk3399\0' > "$T/dt10"
printf 'crestron,uc-p8\0crestron,uc-p10\0rockchip,rk3399\0' > "$T/dt8"
printf 'vendor,other\0' > "$T/dtx"
SH_CODE='echo "model=$(tsx_board_model) dt=$(tsx_board_dt_model) ha=$(tsx_board_ha_model)"'
eq "$(sh_run TSX_DT_COMPATIBLE="$T/dt10")" "model=UC-P10 dt=UC-P10 ha=UC-P10" "crestron,uc-p10"
eq "$(sh_run TSX_DT_COMPATIBLE="$T/dt8")" "model=UC-P8 dt=UC-P8 ha=UC-P8" "crestron,uc-p8 comes first in the list"
eq "$(sh_run TSX_DT_COMPATIBLE="$T/dtx")" "model= dt= ha=" "an unknown compatible gives no model"
eq "$(sh_run TSX_DT_COMPATIBLE="$T/none")" "model= dt= ha=" "no device tree: no model"

echo "== the files that name the board =="
grep -qx 'ttyS2' "$HERE/overlay/etc/securetty" && ok "securetty lists ttyS2" || bad "securetty lacks ttyS2"
grep -q 'ttyS2' "$HERE/overlay/etc/inittab" && ok "inittab has a getty on ttyS2" || bad "inittab lacks ttyS2"
grep -q '^LABEL=tsxroot[[:space:]]*/[[:space:]]' "$HERE/overlay/etc/fstab" && ok "fstab: root by the label tsxroot" || bad "fstab: no root"
grep -q '^LABEL=tsxdata[[:space:]]*/data[[:space:]]' "$HERE/overlay/etc/fstab" && ok "fstab: /data by the label tsxdata" || bad "fstab: no /data"
codes=$(awk '$1 == "button" { print $3 }' "$HERE/overlay/etc/tsx/buttons-board.conf" | tr '\n' ' ')
eq "$codes" "113 115 114 202 149 148 " "buttons-board.conf: the six key codes"
echo "$N passed, $F failed"
[ "$F" = 0 ]
