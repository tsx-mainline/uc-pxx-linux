#!/bin/sh
# Host test for uc-pxx-presence. It uses a made-up /sys/class/input, a file in
# place of the EVIOCGSW ioctl and a stub for tsx-blank. It checks:
#   - the find of the PIR switch (name gpio-keys, switch bit 11)
#   - the ioctl number and the bit test
#   - presence on at once, off after PRESENCE_HOLD_S, the wake call
#   - PRESENCE_WAKE=off, the state at start, a reload with SIGHUP
# The ioctl itself needs a real input device. Nothing here covers it.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PRES=$HERE/overlay/usr/local/sbin/uc-pxx-presence
INIT=$HERE/overlay/etc/init.d/uc-pxx-presence
T=$(mktemp -d); trap 'rm -rf "$T"; kill $BG 2>/dev/null' EXIT
BG=
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: no python3"; exit 0; }

echo "== syntax =="
python3 -I -m py_compile "$PRES" && ok "uc-pxx-presence compiles" || bad "uc-pxx-presence: py_compile"
find "$HERE/overlay" -name __pycache__ -exec rm -rf {} + 2>/dev/null
busybox sh -n "$INIT" && ok "the init script passes busybox sh -n" || bad "the init script: busybox sh -n"
[ -x "$PRES" ] && [ -x "$INIT" ] && ok "both files are executable" || bad "a file is not executable"

echo "== the ioctl number and the bit test =="
out=$(PYTHONDONTWRITEBYTECODE=1 python3 -I - "$PRES" <<'P'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("pres", sys.argv[1])
spec = importlib.util.spec_from_loader("pres", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
print("%#x" % m.eviocgsw(8))
print("%#x" % m.eviocgsw(1))
b = bytearray(8); b[1] = 0x0a; b[2] = 0x00   # a20: bits 5, 9 and 11
print([i for i in range(16) if m.sw_bit(b, i)])
b[1] = 0x02
print(m.sw_bit(b, 11))
P
)
eq "$(echo "$out" | sed -n 1p)" "0x8008451b" "EVIOCGSW(8) = 0x8008451b"
eq "$(echo "$out" | sed -n 2p)" "0x8001451b" "EVIOCGSW(1) = 0x8001451b"
eq "$(echo "$out" | sed -n 3p)" "[9, 11]" "bits 9 and 11 of the bytes 00 0a"
eq "$(echo "$out" | sed -n 4p)" "False" "bit 11 clear"

# mksys SW: a made-up /sys/class/input. SW: the switch bits of gpio-keys (empty = no such device)
mksys() {
	rm -rf "$T/sys" "$T/dev"; mkdir -p "$T/sys/input0/capabilities" "$T/dev"
	echo mXT1066 > "$T/sys/input0/name"; echo 0 > "$T/sys/input0/capabilities/sw"
	mkdir "$T/sys/input0/event0"
	if [ -n "${1:-}" ]; then
		mkdir -p "$T/sys/input4/capabilities" "$T/sys/input4/event4"
		echo gpio-keys > "$T/sys/input4/name"; echo "$1" > "$T/sys/input4/capabilities/sw"
	fi
}
# the common part of the environment. FAKE: 1 = use the file in place of the ioctl
pres() {
	${EXEC:-} env -i PATH="$PATH" PYTHONDONTWRITEBYTECODE=1 TSX_RUN_DIR="$T/run" TSX_SENSORS_CONF="$T/sensors.conf" \
		TSX_SYS_INPUT="$T/sys" TSX_DEV_INPUT="$T/dev" TSX_BLANK="$T/blank" ${SW:+UC_PXX_PRESENCE_FAKE="$T/sw"} \
		UC_PXX_PRESENCE_TICK=0.1 ${LOOPS:+UC_PXX_PRESENCE_LOOPS=$LOOPS} "$@"
}
st() { sed -n "s/^$1 //p" "$T/run/presence.state"; }
wakes() { wc -l < "$T/wakes" | tr -d ' '; }
cat > "$T/blank" <<'S'
#!/bin/sh
echo "$*" >> "$(dirname "$0")/wakes"
S
chmod +x "$T/blank"

echo "== find the PIR switch =="
mksys a20; pres python3 -I "$PRES" --probe; eq "$?" "0" "gpio-keys with the switch bits a20: found"
mksys 800; pres python3 -I "$PRES" --probe; eq "$?" "0" "only bit 11: found"
mksys 220; pres python3 -I "$PRES" --probe; eq "$?" "1" "gpio-keys without bit 11 (hook and camera only): not found"
mksys ""; pres python3 -I "$PRES" --probe; eq "$?" "1" "no gpio-keys device: not found"
mksys a20; echo other > "$T/sys/input4/name"; pres python3 -I "$PRES" --probe; eq "$?" "1" "another device name: not found"
mksys a20; rmdir "$T/sys/input4/event4"; pres python3 -I "$PRES" --probe; eq "$?" "1" "no event node: not found"
mksys ""; mkdir -p "$T/run"; pres python3 -I "$PRES"; eq "$?" "0" "no PIR: the daemon exits 0"
[ ! -e "$T/run/presence.state" ] && ok "no PIR: no presence.state" || bad "no PIR: presence.state"
pres python3 -I "$PRES" --bogus; eq "$?" "2" "a wrong argument: exit 2"

echo "== the states (the file stands in for the ioctl) =="
mksys a20; rm -rf "$T/run"; : > "$T/sensors.conf"; : > "$T/wakes"; echo 0 > "$T/sw"
( SW=1 EXEC=exec pres python3 -I "$PRES" ) &
BG=$!
sleep 0.6
eq "$(st present)|$(st distance)|$(st motion)" "off|none|off" "no motion: present off, distance none"
eq "$(st wake)|$(st hold_s)" "on|30" "wake on and hold 30 s by default"
echo 1 > "$T/sw"; sleep 0.6
eq "$(st present)|$(st motion)" "on|on" "motion: present on at once"
eq "$(wakes)" "1" "motion: one wake call"
eq "$(cat "$T/wakes")" "off" "the wake call is: tsx-blank off"
sleep 0.5; eq "$(wakes)" "1" "motion that goes on: no second wake call"
echo 0 > "$T/sw"; sleep 0.6
eq "$(st present)|$(st motion)" "on|off" "switch back to 0: present stays on (hold)"
echo 1 > "$T/sw"; sleep 0.4; echo 0 > "$T/sw"; sleep 0.4
eq "$(wakes)" "1" "motion again while present is on: no wake call"
echo 'PRESENCE_HOLD_S="1"' > "$T/sensors.conf"; kill -HUP $BG; sleep 0.5
eq "$(st hold_s)" "1" "SIGHUP: PRESENCE_HOLD_S=1"
sleep 1.6
eq "$(st present)" "off" "1 s without motion: present off"
echo 1 > "$T/sw"; sleep 0.6
eq "$(st present)|$(wakes)" "on|2" "motion after away: present on, a second wake call"
echo 0 > "$T/sw"
echo 'PRESENCE_WAKE="off"' >> "$T/sensors.conf"; kill -HUP $BG; sleep 2
eq "$(st present)|$(st wake)" "off|off" "PRESENCE_WAKE=off in the state"
echo 1 > "$T/sw"; sleep 0.6
eq "$(st present)|$(wakes)" "on|2" "PRESENCE_WAKE=off: present on, no wake call"
echo garbage > "$T/sw"; sleep 0.5
eq "$(st present)" "on" "a switch that cannot be read keeps the state"
echo 1 > "$T/sw"; echo 'PRESENCE_HOLD_S="9999"' > "$T/sensors.conf"; kill -HUP $BG; sleep 0.5
eq "$(st hold_s)" "30" "PRESENCE_HOLD_S out of range: 30"
kill -TERM $BG; wait $BG 2>/dev/null; BG=

echo "== the state at start =="
mksys a20; rm -rf "$T/run"; : > "$T/sensors.conf"; : > "$T/wakes"; echo 1 > "$T/sw"
( SW=1 LOOPS=3 pres python3 -I "$PRES" )
eq "$(st present)|$(st motion)|$(wakes)" "on|on|0" "motion at start: present on, no wake call"
echo 0 > "$T/sw"; rm -rf "$T/run"
( SW=1 LOOPS=3 pres python3 -I "$PRES" )
eq "$(st present)" "off" "no motion at start: present off"
[ "$(stat -c %a "$T/run/presence.state")" = 644 ] && ok "presence.state has mode 644" || bad "presence.state mode"

echo "$N passed, $F failed"
[ "$F" = 0 ]
