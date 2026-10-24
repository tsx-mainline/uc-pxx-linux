#!/bin/sh
# Host test for uc-pxx-als and tsx-als. It uses a made-up IIO device, backlight
# and /run/tsx. It checks:
#   - counts to lux (counts x in_illuminance_scale x ALS_SCALE), with the
#     three readings of the tested unit: room 58, covered 1, flashlight 138
#   - the files als.state and als-level, and AUTO_BRIGHTNESS off
#   - the backlight range from the board file and from the device
#   - a missing sensor, a bad reading, a reload with SIGHUP
#   - the tsx-als command
# The shared module tsx_brightness.py (tsx-linux-common) gives the debounce
# and the learning. The test runs without it (plain light) and, when a
# checkout of tsx-linux-common is next to this repository or TSX_COMMON_DIR
# names one, also with it.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
ALS=$HERE/overlay/usr/local/sbin/uc-pxx-als
TSXALS=$HERE/overlay/usr/local/sbin/tsx-als
INIT=$HERE/overlay/etc/init.d/uc-pxx-als
T=$(mktemp -d); trap 'rm -rf "$T"; kill $BG 2>/dev/null' EXIT
BG=
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: no python3"; exit 0; }

echo "== syntax =="
python3 -I -m py_compile "$ALS" && ok "uc-pxx-als compiles" || bad "uc-pxx-als: py_compile"
find "$HERE/overlay" -name __pycache__ -exec rm -rf {} + 2>/dev/null
busybox sh -n "$TSXALS" && ok "tsx-als passes busybox sh -n" || bad "tsx-als: busybox sh -n"
busybox sh -n "$INIT" && ok "the init script passes busybox sh -n" || bad "the init script: busybox sh -n"
[ -x "$ALS" ] && [ -x "$TSXALS" ] && [ -x "$INIT" ] && ok "the three files are executable" || bad "a file is not executable"

COMMON=${TSX_COMMON_DIR:-$HERE/../../tsx-linux-common}/base/usr/local/lib/tsx
[ -r "$COMMON/tsx_brightness.py" ] || COMMON=

# setup [COUNTS [SCALE]]: a fresh fake system
setup() {
	rm -rf "$T/sys" "$T/run" "$T/bl"
	mkdir -p "$T/sys/iio:device0" "$T/run" "$T/bl/backlight/bl0"
	echo jsa1212 > "$T/sys/iio:device0/name"
	echo "${1-58}" > "$T/sys/iio:device0/in_illuminance_raw"
	[ "${2-0.5}" = none ] || echo "${2-0.5}" > "$T/sys/iio:device0/in_illuminance_scale"
	echo 4 > "$T/bl/backlight/bl0/max_brightness"
	: > "$T/board.conf"; : > "$T/kiosk.conf"; : > "$T/sensors.conf"
}
# daemon ARGS...: run the daemon for a few passes. LIB: the folder of tsx_brightness.py
daemon() {
	env -i PATH="$PATH" PYTHONDONTWRITEBYTECODE=1 TSX_RUN_DIR="$T/run" TSX_SENSORS_CONF="$T/sensors.conf" TSX_KIOSK_CONF="$T/kiosk.conf" \
		TSX_PANEL_BOARD_CONF="$T/board.conf" TSX_IIO_DIR="$T/sys" TSX_BACKLIGHT_DIR="$T/bl/backlight" \
		TSX_LIB_DIR="${LIB:-$T/nolib}" TSX_LEARN_FILE="$T/learn.json" TSX_IDLED_STATE="$T/idled" \
		UC_PXX_ALS_TICK=0.05 UC_PXX_ALS_LOOPS="${LOOPS:-3}" python3 -I "$ALS" "$@" > "$T/out" 2>&1
}
st() { sed -n "s/^$1 //p" "$T/run/als.state"; }
lvl() { cat "$T/run/als-level" 2>/dev/null; }
# the default.conf of the board, as tsx-hw writes it
cp "$HERE/overlay/etc/tsx/panel-board.d/default.conf" "$T/default.conf"

run_suite() {
echo "== counts to lux: the three readings of the tested unit =="
setup 58; cp "$T/default.conf" "$T/board.conf"; daemon; eq "$?" "0" "exit 0"
eq "$(st raw)|$(st report)|$(st counts)" "29.00|29.0|58" "room: 58 counts = 29 lux"
eq "$(st auto)|$(st scale)" "on|1.00" "auto on while panel.conf says nothing, scale 1"
eq "$(lvl)" "3" "room: level 3 of 1 to 4"
setup 1; cp "$T/default.conf" "$T/board.conf"; daemon
eq "$(st raw)|$(st counts)|$(lvl)" "0.50|1|1" "covered: 1 count = 0.5 lux, the lowest level"
setup 138; cp "$T/default.conf" "$T/board.conf"; daemon
eq "$(st raw)|$(st counts)|$(lvl)" "69.00|138|3" "flashlight: 138 counts = 69 lux"
setup 4095; cp "$T/default.conf" "$T/board.conf"; daemon
eq "$(st raw)|$(lvl)" "2047.50|4" "full scale: 4095 counts = 2047.5 lux, the top level"
setup 0; cp "$T/default.conf" "$T/board.conf"; daemon
eq "$(st raw)|$(lvl)" "0.00|1" "dark: 0 lux, the lowest level (never 0)"

echo "== the scale =="
setup 58 none; daemon
eq "$(st raw)" "29.00" "no in_illuminance_scale file: 0.5 lux per count"
setup 58 1.0; daemon
eq "$(st raw)" "58.00" "in_illuminance_scale 1.0: 58 lux"
setup 58; echo 'ALS_SCALE="2"' > "$T/sensors.conf"; daemon
eq "$(st raw)|$(st scale)" "58.00|2.00" "ALS_SCALE=2 in sensors.conf"
setup 58; echo 'ALS_SCALE=3' > "$T/board.conf"; daemon
eq "$(st raw)" "87.00" "ALS_SCALE=3 in the board file"
setup 58; echo 'ALS_SCALE=3' > "$T/board.conf"; echo 'ALS_SCALE="2"' > "$T/sensors.conf"; daemon
eq "$(st raw)" "58.00" "ALS_SCALE of panel.conf wins over the board file"
setup 58; echo 'ALS_SCALE=5000' > "$T/sensors.conf"; daemon
eq "$(st raw)" "29.00" "ALS_SCALE out of range: 1"

echo "== AUTO_BRIGHTNESS =="
setup 58; echo 'AUTO_BRIGHTNESS="off"' > "$T/sensors.conf"; echo 3 > "$T/run/als-level"; daemon
eq "$(st auto)" "off" "off: als.state says off"
[ ! -e "$T/run/als-level" ] && ok "off: no als-level" || bad "off: als-level exists"
eq "$(st raw)" "29.00" "off: the light is still reported"
setup 58; echo 'AUTO_BRIGHTNESS="on"' > "$T/sensors.conf"; daemon
eq "$(st auto)" "on" "on: als.state says on"

echo "== the backlight range =="
setup 4095; printf 'BACKLIGHT_MAX=2\nBACKLIGHT_MIN=1\nBRIGHTNESS_DAY=2\nBRIGHTNESS_NIGHT=1\n' > "$T/board.conf"; daemon
eq "$(lvl)" "2" "BACKLIGHT_MAX=2 in the board file: the top level is 2"
setup 4095; echo 9 > "$T/bl/backlight/bl0/max_brightness"; : > "$T/board.conf"; daemon
eq "$(lvl)" "9" "no board file: the top level is max_brightness of the device"
setup 4095; printf 'BACKLIGHT_MAX=20\nBRIGHTNESS_DAY=20\n' > "$T/board.conf"; daemon
eq "$(lvl)" "4" "the device limit wins over BACKLIGHT_MAX"
setup 4095; rm -rf "$T/bl/backlight/bl0/max_brightness"; : > "$T/board.conf"; daemon
eq "$(lvl)" "4" "no backlight device value: the 4 steps of the device tree"
setup 0; printf 'BACKLIGHT_MAX=4\nBACKLIGHT_MIN=2\nBRIGHTNESS_NIGHT=1\n' > "$T/board.conf"; daemon
eq "$(lvl)" "2" "BACKLIGHT_MIN is the floor"

echo "== the sensor is missing or gives no number =="
setup 58; rm -rf "$T/sys/iio:device0"; daemon; eq "$?" "0" "no device: exit 0"
grep -q 'nothing to do' "$T/out" && ok "no device: says so" || bad "no device: no message"
[ ! -e "$T/run/als.state" ] && ok "no device: no als.state" || bad "no device: als.state"
daemon --probe; eq "$?" "1" "--probe: exit 1 without the sensor"
setup 58; daemon --probe; eq "$?" "0" "--probe: exit 0 with the sensor"
setup 58; echo 'jsa1212x' > "$T/sys/iio:device0/name"; daemon --probe; eq "$?" "1" "another IIO name does not count"
setup ""; daemon; eq "$?" "0" "an empty reading: no crash"
[ ! -e "$T/run/als-level" ] && ok "an empty reading: no als-level" || bad "an empty reading: als-level $(lvl)"
setup abc; daemon; eq "$?" "0" "a reading that is no number: no crash"
[ ! -e "$T/run/als-level" ] && ok "a bad reading: no als-level" || bad "a bad reading: als-level"
daemon --bogus; eq "$?" "2" "a wrong argument: exit 2"

echo "== a reload with SIGHUP =="
setup 58; cp "$T/default.conf" "$T/board.conf"
env -i PATH="$PATH" PYTHONDONTWRITEBYTECODE=1 TSX_RUN_DIR="$T/run" TSX_SENSORS_CONF="$T/sensors.conf" TSX_KIOSK_CONF="$T/kiosk.conf" \
	TSX_PANEL_BOARD_CONF="$T/board.conf" TSX_IIO_DIR="$T/sys" TSX_BACKLIGHT_DIR="$T/bl/backlight" \
	TSX_LIB_DIR="${LIB:-$T/nolib}" TSX_LEARN_FILE="$T/learn.json" TSX_IDLED_STATE="$T/idled" \
	UC_PXX_ALS_TICK=0.05 python3 -I "$ALS" > "$T/bg.out" 2>&1 &
BG=$!
sleep 1
eq "$(st auto)|$(st raw)" "on|29.00" "the daemon runs: auto on"
echo 'AUTO_BRIGHTNESS="off"' > "$T/sensors.conf"; echo 'ALS_SCALE="2"' >> "$T/sensors.conf"
kill -HUP $BG; sleep 1
eq "$(st auto)|$(st raw)" "off|58.00" "after SIGHUP: auto off, scale 2"
[ ! -e "$T/run/als-level" ] && ok "after SIGHUP: no als-level" || bad "after SIGHUP: als-level"
echo 'AUTO_BRIGHTNESS="on"' > "$T/sensors.conf"; echo 4095 > "$T/sys/iio:device0/in_illuminance_raw"
kill -HUP $BG; sleep 1
eq "$(st auto)|$(lvl)" "on|4" "after a second SIGHUP: auto on, the level is back"
kill -TERM $BG; wait $BG 2>/dev/null; BG=
[ ! -e "$T/run/als-level" ] && ok "SIGTERM removes als-level" || bad "SIGTERM left als-level"
}

echo "##### without tsx_brightness.py (plain light)"
LIB=
run_suite
if [ -n "$COMMON" ]; then
	echo "##### with tsx_brightness.py from $COMMON"
	LIB=$COMMON
	run_suite
else
	echo "SKIPPED: no tsx-linux-common checkout (set TSX_COMMON_DIR), the run with tsx_brightness.py"
fi

echo "== tsx-als =="
mkdir -p "$T/ctl"
cat > "$T/ctl/tsx-config" <<'S'
#!/bin/sh
echo "tsx-config $*" >> "$(dirname "$0")/calls"
S
chmod +x "$T/ctl/tsx-config"; : > "$T/ctl/calls"
TSX_CONFIG_BIN=$T/ctl/tsx-config sh "$TSXALS" auto off
TSX_CONFIG_BIN=$T/ctl/tsx-config sh "$TSXALS" auto on
eq "$(tr '\n' ';' < "$T/ctl/calls")" "tsx-config set AUTO_BRIGHTNESS off;tsx-config apply;tsx-config set AUTO_BRIGHTNESS on;tsx-config apply;" "auto on|off: set, then apply"
sh "$TSXALS" auto maybe 2>/dev/null; eq "$?" "2" "auto with a wrong word: exit 2"
sh "$TSXALS" bogus 2>/dev/null; eq "$?" "2" "a wrong command: exit 2"
mkdir -p "$T/run2"; printf 'raw 29.00\nauto on\n' > "$T/run2/als.state"
eq "$(TSX_RUN_DIR=$T/run2 sh "$TSXALS" status | head -n 1)" "raw 29.00" "status shows als.state"
TSX_RUN_DIR=$T/none sh "$TSXALS" status 2>/dev/null; eq "$?" "1" "status without the file: exit 1"

echo "$N passed, $F failed"
[ "$F" = 0 ]
