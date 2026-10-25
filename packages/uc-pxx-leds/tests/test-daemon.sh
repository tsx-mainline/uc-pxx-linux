#!/bin/sh
# Host test for the daemon uc-pxx-leds. It uses a made-up /sys/class/leds, a
# stub for uc-pxx-bootctl and real sockets. It checks:
#   - the parser: only the fixed command forms run, every other line is refused
#   - the start state: indicators off, a slow blue blink until the system is
#     ready, then green for BOOT_OK_HOLD_S, then off; commands for the status
#     LED are refused before the boot is good (the A/B mark)
#   - READY: the sources kiosk, openrc, bootctl and auto, the timeout fallback
#   - the indicators and the status LED: colors, kernel triggers, software patterns
#   - the red LED: the latch, the rule that red is never written when it is
#     not ours, and no write at all while the boot is not good
#   - persistence, the state file and the control socket (mode, group, bad
#     clients, signals)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROG=$HERE/root/usr/local/sbin/uc-pxx-leds
INIT=$HERE/root/etc/init.d/uc-pxx-leds
CONF=$HERE/root/etc/tsx/uc-pxx-leds.conf
T=$(mktemp -d); trap 'rm -rf "$T"; [ -z "${BG:-}" ] || kill $BG 2>/dev/null' EXIT
BG=
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: no python3"; exit 0; }
export PYTHONDONTWRITEBYTECODE=1

echo "== files =="
[ -x "$PROG" ] && [ -x "$INIT" ] && ok "the daemon and the init script are executable" || bad "a file is not executable"
python3 -I -B -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PROG" && ok "the daemon parses" || bad "the daemon does not parse"
busybox sh -n "$INIT" && ok "the init script passes busybox sh -n" || bad "the init script: busybox sh -n"
head -n 1 "$INIT" | grep -qx '#!/sbin/openrc-run' && ok "the init script is an OpenRC script" || bad "no openrc-run line"
grep -qx 'PERSIST=no' "$CONF" && ok "the shipped config has PERSIST=no" || bad "the shipped config does not have PERSIST=no"
grep -qx 'READY_SOURCE=auto' "$CONF" && ok "the shipped config has READY_SOURCE=auto" || bad "the shipped config does not have READY_SOURCE=auto"
grep -qx 'READY_TIMEOUT_S=180' "$CONF" && ok "the shipped config has READY_TIMEOUT_S=180" || bad "the shipped config does not have READY_TIMEOUT_S=180"
grep -qx 'BOOT_OK_HOLD_S=10' "$CONF" && ok "the shipped config has BOOT_OK_HOLD_S=10" || bad "the shipped config does not have BOOT_OK_HOLD_S=10"
grep -q 'uc-pxx-bootctl' "$PROG" && ok "the daemon names uc-pxx-bootctl" || bad "no bootctl"
grep -Eq 'bootctl.*(mark-successful|arm|--file)|"(mark-successful|arm-trying)"' "$PROG" && bad "the daemon may call a bootctl command that writes" || ok "the daemon calls only 'bootctl status'"
grep -c 'BOOTCTL, "status"' "$PROG" | grep -qx 1 && ok "bootctl runs in one place, with the argument status" || bad "bootctl is called in more than one place"

# a stub of uc-pxx-bootctl: the state comes from two files
cat > "$T/bootctl" <<'S'
#!/bin/sh
D=$(dirname "$0")
[ "$*" = "status" ] || { echo "stub: bad arguments: $*" >&2; exit 9; }
s=$(cat "$D/bootctl.succ" 2>/dev/null)
[ -z "$s" ] || echo "uc-pxx-bootctl: current: A{prio 15 tries 7 succ $s} B{prio 14 tries 7 succ 1} crc 00000000" >&2
exit "$(cat "$D/bootctl.rc" 2>/dev/null || echo 0)"
S
chmod +x "$T/bootctl"
ENVV="UC_PXX_LEDS=$T/leds UC_PXX_LEDS_SOCK=$T/run/sock UC_PXX_LEDS_STATE=$T/state UC_PXX_LEDS_CONF=$T/conf UC_PXX_LEDS_SAVE=$T/saved UC_PXX_BOOTCTL=$T/bootctl UC_PXX_SLOT_MARK=$T/mark TSX_RUN_DIR=$T/run UC_PXX_LEDS_GROUPS=nosuchgroup UC_PXX_READY_SOURCE=bootctl"

echo "== the module, with made-up LEDs =="
env -i PATH="$PATH" PYTHONDONTWRITEBYTECODE=1 $ENVV python3 -I -B "$HERE/tests/check_daemon.py" "$PROG" "$T"
[ $? = 0 ] && ok "the module checks" || bad "the module checks"

echo "== the daemon with a socket =="
GRP=$(id -gn)
mkdir -p "$T/leds" "$T/run"
for l in teams_white mute_headset mute_speaker mute_red red green blue; do
	mkdir -p "$T/leds/$l"; echo 0 > "$T/leds/$l/brightness"; echo "[none] timer heartbeat" > "$T/leds/$l/trigger"
done
echo 1 > "$T/bootctl.succ"; rm -f "$T/conf" "$T/mark"
send() { python3 -I -B - "$T/run/sock" "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1])
data = b""
try:
    s.sendall(sys.argv[2].encode("latin-1").decode("unicode_escape").encode("latin-1"))
    s.shutdown(socket.SHUT_WR)
    while True:
        c = s.recv(4096)
        if not c: break
        data += c
except (ConnectionResetError, BrokenPipeError):
    pass
sys.stdout.write(data.decode("ascii", "replace"))
PY
}
env -i PATH="$PATH" $ENVV UC_PXX_LEDS_GROUPS="nosuchgroup $GRP" python3 -I -B "$PROG" 2> "$T/daemon.log" &
BG=$!
i=0; while [ ! -S "$T/run/sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$T/run/sock" ] && ok "the socket exists" || bad "no socket: $(cat "$T/daemon.log")"
eq "$(stat -c %a "$T/run/sock")" "660" "the socket has mode 660 (group of the list)"
eq "$(stat -c %G "$T/run/sock")" "$GRP" "the socket has the group from the list"
sleep 0.3
eq "$(send 'ind teams on\n')" "ok" "a command answers ok"
eq "$(cat "$T/leds/teams_white/brightness")" "1" "and the LED is on when the answer arrives"
eq "$(sed -n 's/^teams //p' "$T/state")" "on" "and the state file is written when the answer arrives"
eq "$(send 'status red blink fast\n')" "ok" "a status command (the boot is good)"
sleep 0.5
eq "$(send 'bogus\n')" "err bad-command" "a bad command is refused"
grep -q "refused: bogus" "$T/daemon.log" && ok "and logged" || bad "no refusal in the log"
eq "$(send 'ind teams on')" "ok" "a client that closes without a newline still gets its line run"
eq "$(send 'get\n' | sed -n 1p)" "boot ok" "get returns the state text"
eq "$(send 'ind teams on\nind teams off\n')" "ok" "only the first line of a client runs"
eq "$(cat "$T/leds/teams_white/brightness")" "1" "and the second line did not run"
send "$(python3 -c 'print("x" * 600, end="")')\n" > /dev/null
eq "$(send 'ind teams on\n')" "ok" "a long line does not stop the daemon"
eq "$(send 'ind teams on\n')" "ok" "and is not run"
eq "$(send 'ind teams on\x00\n')" "err bad-line" "a NUL byte is refused"
eq "$(send '\xff\xfe\n')" "err bad-line" "a non-ASCII line is refused"
# a client that sends nothing does not stop the others
python3 -I -B -c "
import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(3)" "$T/run/sock" &
SLOW=$!
sleep 0.3
eq "$(send 'ind teams on\n')" "ok" "a silent client does not block the next one"
wait $SLOW
eq "$(sed -n 1p "$T/state")" "boot ok" "the state file says boot ok"
[ "$(stat -c %a "$T/state")" = 644 ] && ok "the state file has mode 644" || bad "state file mode"
# the marker of a changed slot A
: > "$T/mark"; sleep 0.8
eq "$(sed -n 1p "$T/state")" "boot locked" "the marker changes the state file to locked"
eq "$(send 'status green\n')" "err boot-locked" "and the status LED refuses commands"
rm -f "$T/mark"
# red lit by another program
send 'status auto\n' > /dev/null; sleep 0.8
echo 1 > "$T/leds/red/brightness"; sleep 0.8
eq "$(sed -n 3p "$T/state")" "red latched" "red lit by another program: latched in the state file"
# reload and signals
printf 'PERSIST=yes\n' > "$T/conf"; kill -HUP $BG; sleep 0.8
eq "$(sed -n 's/^persist //p' "$T/state")" "yes" "SIGHUP reads the config again"
[ -f "$T/saved" ] && ok "and the state is saved at once" || bad "no save file after the reload"
kill -TERM $BG; wait $BG; eq "$?" "0" "SIGTERM ends the daemon with exit 0"; BG=
[ ! -e "$T/run/sock" ] && ok "the socket is removed" || bad "the socket stays"
eq "$(cat "$T/leds/teams_white/brightness")" "1" "the LEDs keep their state when the daemon ends"
# a stale socket is replaced
: > "$T/run/sock"
env -i PATH="$PATH" $ENVV python3 -I -B "$PROG" 2>> "$T/daemon.log" &
BG=$!
i=0; while [ ! -S "$T/run/sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -S "$T/run/sock" ] && ok "a stale file at the socket path is replaced" || bad "the stale file blocks the socket"
eq "$(stat -c %a "$T/run/sock")" "600" "no group found: mode 600"
sleep 0.5; eq "$(sed -n 's/^teams //p' "$T/state")" "on" "the saved state plays back after a restart (PERSIST=yes)"
kill -TERM $BG; wait $BG; BG=
python3 -I -B "$PROG" bogus 2>/dev/null; eq "$?" "2" "a wrong argument: exit 2"

echo "== a blue blink that the kernel and /init started is not restarted =="
# trigger_file: the content shows which trigger is selected. The daemon writes
# only the name, so a changed file means that the daemon wrote the trigger.
mkblue() { # DELAY_OFF
	rm -rf "$T/leds2"; mkdir -p "$T/leds2"
	for l in teams_white mute_headset mute_speaker mute_red red green blue; do
		mkdir -p "$T/leds2/$l"; echo 0 > "$T/leds2/$l/brightness"; echo "none [timer] heartbeat" > "$T/leds2/$l/trigger"
	done
	echo 500 > "$T/leds2/blue/delay_on"; echo "$1" > "$T/leds2/blue/delay_off"
	rm -f "$T/run/sock" "$T/kiosk.ready"
}
runblue() {
	env -i PATH="$PATH" $ENVV UC_PXX_LEDS="$T/leds2" UC_PXX_READY_SOURCE=kiosk UC_PXX_KIOSK_READY="$T/kiosk.ready" python3 -I -B "$PROG" 2>> "$T/daemon.log" &
	BG=$!
	i=0; while [ ! -S "$T/run/sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	sleep 0.6
}
mkblue 1500; runblue
eq "$(cat "$T/leds2/blue/trigger")" "none [timer] heartbeat" "same timer and delays: the trigger is not written again"
eq "$(cat "$T/leds2/blue/delay_off")" "1500" "and the delays are not written again"
eq "$(cat "$T/leds2/green/trigger")" "none" "the other LEDs are set as before (green: no trigger)"
eq "$(cat "$T/leds2/red/brightness")" "0" "red stays off"
# when the system is READY the daemon goes on as before: green, no blink
: > "$T/kiosk.ready"; sleep 2.6
eq "$(cat "$T/leds2/green/brightness")" "1" "READY: green on as before"
eq "$(cat "$T/leds2/blue/trigger")" "none" "READY: the blue blink ends"
kill -TERM $BG; wait $BG; BG=
mkblue 1000; runblue
eq "$(cat "$T/leds2/blue/trigger")" "timer" "other delays: the daemon sets the trigger"
eq "$(cat "$T/leds2/blue/delay_off")" "1500" "and the boot timing"
kill -TERM $BG; wait $BG; BG=

echo "$N passed, $F failed"
[ "$F" = 0 ]
