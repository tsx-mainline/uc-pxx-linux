#!/bin/sh
# Host test for the command uc-pxx-led. It runs the real daemon against a
# made-up /sys/class/leds and a stub for uc-pxx-bootctl, and checks the
# arguments, the exit status and the output of the command.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROG=$HERE/root/usr/local/sbin/uc-pxx-leds
CLI=$HERE/root/usr/local/bin/uc-pxx-led
T=$(mktemp -d); trap 'rm -rf "$T"; [ -z "${BG:-}" ] || kill $BG 2>/dev/null' EXIT
BG=
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: no python3"; exit 0; }
export PYTHONDONTWRITEBYTECODE=1

[ -x "$CLI" ] && ok "the command is executable" || bad "the command is not executable"
python3 -I -B -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$CLI" && ok "the command parses" || bad "the command does not parse"

mkdir -p "$T/leds" "$T/run"
for l in teams_white mute_headset mute_speaker mute_red red green blue; do
	mkdir -p "$T/leds/$l"; echo 0 > "$T/leds/$l/brightness"; echo "[none] timer heartbeat" > "$T/leds/$l/trigger"
done
printf '#!/bin/sh\necho "uc-pxx-bootctl: current: A{prio 15 tries 7 succ $(cat "$(dirname "$0")/succ")} B{prio 14 tries 7 succ 1} crc 0" >&2\n' > "$T/bootctl"
chmod +x "$T/bootctl"; echo 0 > "$T/succ"
ENVV="UC_PXX_LEDS=$T/leds UC_PXX_LEDS_SOCK=$T/run/sock UC_PXX_LEDS_STATE=$T/state UC_PXX_LEDS_CONF=$T/none UC_PXX_LEDS_SAVE=$T/saved UC_PXX_BOOTCTL=$T/bootctl UC_PXX_SLOT_MARK=$T/mark TSX_RUN_DIR=$T/run UC_PXX_LEDS_GROUPS=nosuchgroup UC_PXX_BOOT_POLL=0.3"
led() { cat "$T/leds/$1/brightness"; }
cli() { env -i PATH="$PATH" $ENVV python3 -I -B "$CLI" "$@"; }

echo "== no daemon =="
cli teams on 2> "$T/err"; eq "$?" "3" "no daemon: exit 3"
grep -q "does not answer" "$T/err" && ok "and a message" || bad "no message"
cli show > "$T/out" 2> "$T/err"; eq "$?" "3" "show without a daemon or state file: exit 3"
printf 'boot ok\nred free\nteams on\nheadset off\nspeaker off\nmic off\nstatus auto\nshown green solid\npersist no\n' > "$T/state"
cli show > "$T/out" 2> "$T/err"; eq "$?" "0" "show reads the last state file when the daemon is gone"
grep -q "last state file" "$T/out" && ok "and says so" || bad "show does not say that the file is old"
rm -f "$T/state"

env -i PATH="$PATH" $ENVV python3 -I -B "$PROG" 2> "$T/daemon.log" &
BG=$!
i=0; while [ ! -S "$T/run/sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.3

echo "== the indicators =="
cli teams on; eq "$?:$(led teams_white)" "0:1" "teams on"
cli headset on; cli speaker on; cli mic on
eq "$(led mute_headset)$(led mute_speaker)$(led mute_red)" "111" "headset, speaker and mic on"
cli teams off; eq "$?:$(led teams_white)" "0:0" "teams off"
cli mic blink; eq "$?:$(cat "$T/leds/mute_red/trigger"):$(cat "$T/leds/mute_red/delay_on")" "0:timer:500" "mic blink is slow"
cli mic blink fast; eq "$(cat "$T/leds/mute_red/delay_on")" "125" "mic blink fast"
cli mic off; eq "$(led mute_red):$(cat "$T/leds/mute_red/trigger")" "0:none" "mic off ends the blink"
cli speaker off; cli headset off

echo "== the status LED =="
cli status green 2> "$T/err"; eq "$?" "1" "status is refused while the boot is not good: exit 1"
grep -q "boot-wait" "$T/err" && ok "with the reason" || bad "no reason: $(cat "$T/err")"
cli status auto; eq "$?" "0" "status auto is always accepted"
eq "$(cat "$T/leds/blue/trigger"):$(cat "$T/leds/blue/delay_on"):$(cat "$T/leds/blue/delay_off")" "timer:500:1500" "slow blue blink during the boot"
echo 1 > "$T/succ"; sleep 1.2
eq "$(led green):$(led blue)" "1:0" "green after the boot is good"
cli status magenta; eq "$?:$(led red)$(led green)$(led blue)" "0:101" "status magenta"
cli status cyan blink fast; eq "$?:$(cat "$T/leds/blue/trigger"):$(cat "$T/leds/green/delay_on")" "0:timer:125" "status cyan blink fast"
cli status blue heartbeat; eq "$(cat "$T/leds/blue/trigger"):$(led green)" "heartbeat:0" "status blue heartbeat"
cli status off; eq "$(led red)$(led green)$(led blue)" "000" "status off"
cli status auto; eq "$(led green)" "1" "status auto: green during the hold"

echo "== show =="
cli show > "$T/out"; eq "$?" "0" "show: exit 0"
grep -q '^boot      ok$' "$T/out" && ok "show: boot ok" || bad "show: boot line: $(cat "$T/out")"
grep -q '^status    green solid (asked: auto)$' "$T/out" && ok "show: status" || bad "show: status line"
grep -q '^red LED   free$' "$T/out" && ok "show: red LED free" || bad "show: red line"
grep -q '^teams     off$' "$T/out" && ok "show: an indicator" || bad "show: indicator line"
echo 1 > "$T/leds/red/brightness"; sleep 0.8
cli show | grep -q '^red LED   latched$' && ok "show: red LED latched" || bad "show: no latch"

echo "== wrong use =="
for args in "" "teams" "teams maybe" "tv on" "teams on now" "status" "status pink" "status red blink medium" "mic blink slow fast" "show now"; do
	# shellcheck disable=SC2086
	cli $args > /dev/null 2>&1; eq "$?" "2" "usage error: '$args' exits 2"
done
cli teams on-and-more > /dev/null 2>&1; eq "$?" "2" "an unknown state is refused with exit 2"
cli --help > "$T/out" 2>&1; eq "$?" "0" "--help exits 0"
grep -q 'uc-pxx-led status COLOR' "$T/out" && ok "and prints the usage" || bad "no usage"

echo "$N passed, $F failed"
[ "$F" = 0 ]
