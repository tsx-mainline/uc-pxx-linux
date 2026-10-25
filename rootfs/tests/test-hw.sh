#!/bin/sh
# Host test for tsx-hw (the hardware facts and the board values). It uses a
# made-up /sys and runs the real board.sh of the overlay. It checks:
#   - the fixed facts, and PRESENCE and LIGHT from the devices
#   - the layers of panel-board.d (default, model, local)
#   - the real default.conf and the link /etc/tsx/panel-board.conf
#   - get and show
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
O=$HERE/overlay
HW=$O/usr/local/sbin/tsx-hw
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== syntax =="
busybox sh -n "$HW" && ok "tsx-hw passes busybox sh -n" || bad "tsx-hw: busybox sh -n"
[ -x "$HW" ] && ok "tsx-hw is executable" || bad "tsx-hw is not executable"

# mksys DIR [light] [pir]: a made-up /sys. light: the name of the IIO device.
# pir: the switch bits of the input device (a hex word)
mksys() {
	rm -rf "$1"; mkdir -p "$1/bus/iio/devices" "$1/class/input"
	if [ -n "${2:-}" ]; then mkdir -p "$1/bus/iio/devices/iio:device3"; echo "$2" > "$1/bus/iio/devices/iio:device3/name"; fi
	# other input devices that must not count
	mkdir -p "$1/class/input/input0/capabilities"; echo mXT1066 > "$1/class/input/input0/name"; echo 0 > "$1/class/input/input0/capabilities/sw"
	if [ -n "${3:-}" ]; then
		mkdir -p "$1/class/input/input4/capabilities"; echo gpio-keys > "$1/class/input/input4/name"; echo "$3" > "$1/class/input/input4/capabilities/sw"
	fi
}
printf 'crestron,uc-p10\0rockchip,rk3399\0' > "$T/dt10"
printf 'crestron,uc-p8\0rockchip,rk3399\0' > "$T/dt8"
# hw ARGS...: run tsx-hw on the made-up system. The output goes to $T/out
hw() {
	env -i PATH="$PATH" TSX_RUN_DIR="$T/run" TSX_SYS="$T/sys" TSX_BOARD_D="${BD:-$T/bd}" \
		TSX_BOARD_CONF="$O/usr/local/lib/tsx/board.sh" TSX_DT_COMPATIBLE="${DT:-$T/dt10}" "$HW" "$@" > "$T/out" 2>&1
}
fact() { sed -n "s/^$1=//p" "$T/run/hw.conf"; }

echo "== the facts on the unit that was tested (light and PIR present) =="
mksys "$T/sys" jsa1212 a20; mkdir -p "$T/bd"; rm -rf "$T/run"
hw detect; eq "$?" "0" "detect: exit 0"
eq "$(fact LIGHT)-$(fact PRESENCE)" "yes-pir" "LIGHT=yes, PRESENCE=pir"
eq "$(fact MIC)-$(fact BT)-$(fact WIFI)" "yes-yes-yes" "MIC, BT and WIFI are yes"
eq "$(fact LEDBAR)-$(fact CAMERA)" "no-no" "LEDBAR=no, CAMERA=no"
eq "$(fact ORIENTATION_HW)" "landscape" "ORIENTATION_HW=landscape"
eq "$(fact REASON)" "" "REASON is empty"
[ "$(stat -c %a "$T/run/hw.conf")" = 644 ] && ok "hw.conf has mode 644" || bad "hw.conf mode"
grep -q '^tsx-hw: ' "$T/out" && ok "detect prints one summary line" || bad "detect printed no summary"

echo "== a part that is missing =="
mksys "$T/sys" "" a20; rm -rf "$T/run"; hw detect
eq "$(fact LIGHT)-$(fact PRESENCE)" "no-pir" "no jsa1212: LIGHT=no"
eq "$(fact REASON)" "no light sensor" "REASON names the light sensor"
mksys "$T/sys" jsa1212 220; rm -rf "$T/run"; hw detect
eq "$(fact PRESENCE)" "no" "a gpio-keys device without bit 11: PRESENCE=no"
mksys "$T/sys" jsa1212 800; rm -rf "$T/run"; hw detect
eq "$(fact PRESENCE)" "pir" "bit 11 only: PRESENCE=pir"
mksys "$T/sys" other a20; rm -rf "$T/run"; hw detect
eq "$(fact LIGHT)" "no" "an IIO device with another name does not count"
mksys "$T/sys" "" ""; rm -rf "$T/run"; hw detect
eq "$(fact LIGHT)-$(fact PRESENCE)-$(fact REASON)" "no-no-no PIR switch, no light sensor" "both missing"

echo "== get and show =="
eq "$(hw get LIGHT; cat "$T/out")" "no" "get LIGHT"
hw get NOPE; eq "$?" "1" "get of an unknown key: exit 1"
hw get 'bad key'; eq "$?" "2" "get of a bad key name: exit 2"
hw show; grep -q '^MIC=yes$' "$T/out" && ok "show prints the file" || bad "show"
rm -rf "$T/run"; hw get LIGHT; eq "$?" "1" "get without a facts file: exit 1"
hw; eq "$?" "2" "no command: exit 2"

echo "== panel-board.d: default, model and local layers =="
mksys "$T/sys" jsa1212 a20; rm -rf "$T/run" "$T/bd"; mkdir -p "$T/bd"
printf 'A=1\nB=1\nC=1\n# note\n' > "$T/bd/default.conf"
printf 'B=2\n' > "$T/bd/UC-P10.conf"
printf 'B=9\n' > "$T/bd/UC-P8.conf"
printf 'C=3\n' > "$T/bd/local.conf"
hw board; eq "$?" "0" "board: exit 0"
eq "$(grep -v '^#' "$T/run/panel-board.conf" | sort | tr '\n' ' ')" "A=1 B=2 C=3 " "UC-P10: default, UC-P10.conf, local.conf; one line per key"
[ ! -e "$T/run/hw.conf" ] && ok "board writes no facts file" || bad "board wrote hw.conf"
DT=$T/dt8 hw board
eq "$(grep -v '^#' "$T/run/panel-board.conf" | sort | tr '\n' ' ')" "A=1 B=9 C=3 " "UC-P8: its own model file"
DT=$T/none hw board
eq "$(grep -v '^#' "$T/run/panel-board.conf" | sort | tr '\n' ' ')" "A=1 B=1 C=3 " "no model: default and local only"
rm -rf "$T/run" "$T/bd"; mkdir "$T/bd"; hw detect
[ -f "$T/run/panel-board.conf" ] && [ ! -s "$T/run/panel-board.conf" ] && ok "no layer files: an empty board file, no failure" || bad "empty board file"
[ "$(stat -c %a "$T/run/panel-board.conf")" = 644 ] && ok "panel-board.conf has mode 644" || bad "panel-board.conf mode"

echo "== the real default.conf and the link =="
rm -rf "$T/run"; BD=$O/etc/tsx/panel-board.d hw detect
keys=$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$T/run/panel-board.conf" | sort | tr '\n' ' ')
eq "$keys" "ALS_SCALE ALS_WATCH AUTO_BRIGHTNESS_LUX BACKLIGHT_MAX BACKLIGHT_MIN BRIGHTNESS_DAY BRIGHTNESS_NIGHT KIOSK_SCALE " "default.conf: the keys"
busybox sh -c ". '$T/run/panel-board.conf'; [ \"\$BACKLIGHT_MAX\" = 255 ] && [ \"\$BACKLIGHT_MIN\" = 16 ] && [ \"\$BRIGHTNESS_DAY\" = 240 ] && [ \"\$BRIGHTNESS_NIGHT\" = 40 ] && [ \"\$ALS_WATCH\" = 1 ] && [ \"\$KIOSK_SCALE\" = 1.5 ]" && ok "default.conf sources back with the 256 backlight levels and KIOSK_SCALE 1.5" || bad "default.conf does not source"
[ "$(readlink "$O/etc/tsx/panel-board.conf")" = /run/tsx/panel-board.conf ] && ok "/etc/tsx/panel-board.conf is a link to /run/tsx/panel-board.conf" || bad "the link is wrong"

echo "$N passed, $F failed"
[ "$F" = 0 ]
