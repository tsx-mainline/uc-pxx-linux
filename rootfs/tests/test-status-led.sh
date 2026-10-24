#!/bin/sh
# Host test for uc-pxx-status-led. It uses a made-up LED folder and a stub
# for uc-pxx-bootctl. It checks:
#   - blue heartbeat while slot A is not successful, solid green after that
#   - the red LED is never written (also when it is on)
#   - the poll count, the limit, a failed status, a missing LED folder
#   - the stub is the only program that the script runs for the state, and
#     the script calls `status` only
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROG=$HERE/overlay/usr/local/sbin/uc-pxx-status-led
INIT=$HERE/overlay/etc/init.d/uc-pxx-status-led
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== syntax =="
busybox sh -n "$PROG" && ok "uc-pxx-status-led passes busybox sh -n" || bad "uc-pxx-status-led: busybox sh -n"
busybox sh -n "$INIT" && ok "the init script passes busybox sh -n" || bad "the init script: busybox sh -n"
[ -x "$PROG" ] && [ -x "$INIT" ] && ok "both files are executable" || bad "a file is not executable"
head -n 1 "$INIT" | grep -qx '#!/sbin/openrc-run' && ok "the init script is an OpenRC script" || bad "the init script has no openrc-run line"

# mkleds DIR: the fake LED class devices. red starts on.
mkleds() {
	rm -rf "$1"
	for l in green red blue; do mkdir -p "$1/$l"; echo 0 > "$1/$l/brightness"; done
	echo "none [heartbeat]" > "$1/blue/trigger"; echo none > "$1/blue/trigger"
	echo 0 > "$1/green/trigger"; echo none > "$1/green/trigger"
	echo 1 > "$1/red/brightness"
}
# stub STATE...: a status program that prints the next line of a script. The
# counter file says how many calls happened. It records its arguments.
stub() {
	printf '%s\n' "$@" > "$T/script"; : > "$T/calls"; : > "$T/args"
	cat > "$T/bootctl" <<'S'
#!/bin/sh
T=$(dirname "$0")
echo "$*" >> "$T/args"
echo x >> "$T/calls"
n=$(wc -l < "$T/calls")
l=$(sed -n "${n}p" "$T/script"); [ -n "$l" ] || l=$(tail -n 1 "$T/script")
case $l in
rc*) echo "uc-pxx-bootctl: refusing: test" >&2; exit 1;;
*) echo "uc-pxx-bootctl: current: A{prio 15 tries 7 succ $l} B{prio 14 tries 7 succ 1} crc 00000000" >&2
   echo "libavb-would-boot: a"; exit 0;;
esac
S
	chmod +x "$T/bootctl"
}
# run_it MODE: run the program with the stub, the fake LEDs and no waiting
run_it() {
	UC_PXX_LEDS=$T/leds UC_PXX_BOOTCTL=$T/bootctl UC_PXX_LED_SLEEP=true \
	UC_PXX_LED_POLL_S=${POLL:-10} UC_PXX_LED_LIMIT_S=${LIMIT:-600} "$PROG" "$@" > "$T/out" 2>&1
}
led() { echo "$(cat "$T/leds/$1/$2")"; }

echo "== slot A not successful: blue heartbeat =="
mkleds "$T/leds"; stub 0; POLL=10 LIMIT=30 run_it once; rc=$?
eq "$rc" "0" "once: exit 0"
eq "$(led blue trigger)" "heartbeat" "once, trying: the blue trigger is heartbeat"
eq "$(led green brightness)" "0" "once, trying: green is off"
eq "$(led red brightness)" "1" "once, trying: red is not touched (it was on)"

echo "== slot A successful: solid green =="
mkleds "$T/leds"; stub 1; run_it once
eq "$(led blue trigger)-$(led blue brightness)" "none-0" "once, success: blue trigger none and blue off"
eq "$(led green brightness)" "1" "once, success: green is on"
eq "$(led red brightness)" "1" "once, success: red is not touched (it was on)"

echo "== run: trying, trying, then success =="
mkleds "$T/leds"; stub 0 0 1; POLL=10 LIMIT=600 run_it run; rc=$?
eq "$rc" "0" "run: exit 0"
eq "$(wc -l < "$T/calls" | tr -d ' ')" "3" "run: three status calls"
eq "$(led green brightness)-$(led blue brightness)-$(led blue trigger)" "1-0-none" "run: ends with solid green"
grep -q 'slot A is marked successful' "$T/out" && ok "run: logs the change" || bad "run: no log line"

echo "== run: the limit ends while the slot is not successful =="
mkleds "$T/leds"; stub 0; POLL=10 LIMIT=50 run_it run; rc=$?
eq "$rc" "0" "limit: exit 0"
eq "$(wc -l < "$T/calls" | tr -d ' ')" "5" "limit: LIMIT / POLL = 5 status calls"
eq "$(led blue trigger)-$(led green brightness)" "heartbeat-0" "limit: blue keeps the heartbeat, green is off"
grep -q 'not marked successful after 50s' "$T/out" && ok "limit: logs the end" || bad "limit: no log line"

echo "== a status that fails is not a success =="
mkleds "$T/leds"; stub rc rc; POLL=10 LIMIT=20 run_it run
eq "$(led blue trigger)-$(led green brightness)" "heartbeat-0" "failed status: blue heartbeat, green off"
mkleds "$T/leds"; stub rc rc 1; POLL=10 LIMIT=600 run_it run
eq "$(led green brightness)" "1" "a read that fails, then success: green"

echo "== red is never written =="
grep -Eq 'led_write +red|LEDS/red|/red' "$PROG" && bad "the program names the red LED in a write" || ok "the program has no write to red"
mkleds "$T/leds"; chmod -R a-w "$T/leds/red"; stub 0 1; run_it run
eq "$(led red brightness)" "1" "red stays on through the whole run"
chmod -R u+w "$T/leds/red"
mkleds "$T/leds"; rm -rf "$T/leds/red"; stub 0 1; run_it run; rc=$?
eq "$rc-$(led green brightness)" "0-1" "no red LED at all: works"

echo "== the program only reads the A/B state =="
mkleds "$T/leds"; stub 0 1; run_it run
eq "$(sort -u "$T/args" | tr '\n' ' ')" "status " "the only bootctl command is status"
grep -Eq 'mark-successful|arm-trying|uc-pxx-arm-slot|/dev/mmcblk|dd ' "$PROG" && bad "the program names a write command" || ok "the program names no write command"

echo "== other cases =="
mkleds "$T/leds"; stub 1; UC_PXX_LEDS=$T/none UC_PXX_BOOTCTL=$T/bootctl "$PROG" run > "$T/out" 2>&1; rc=$?
eq "$rc" "0" "no LED folder: exit 0"
grep -q 'nothing to do' "$T/out" && ok "no LED folder: says so" || bad "no LED folder: no message"
UC_PXX_LEDS=$T/leds "$PROG" bogus > "$T/out" 2>&1; rc=$?
eq "$rc" "2" "a wrong argument: exit 2"
mkleds "$T/leds"; rm "$T/leds/blue/trigger"; stub 0; run_it once
eq "$(led blue brightness)" "1" "blue without a trigger file: solid blue"

echo "$N passed, $F failed"
[ "$F" = 0 ]
