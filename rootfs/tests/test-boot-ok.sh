#!/bin/sh
# Host test for the OpenRC service rootfs/overlay/etc/init.d/uc-pxx-boot-ok.
# start() and stop() run from a copy whose fixed paths point into a temporary
# directory, with stub OpenRC functions and a stub hook. The stub hook writes
# one line for each run and then sleeps. rootfs/tests/test-boot-ok-openrc.sh
# runs the same service under a real OpenRC.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT=$HERE/overlay/etc/init.d/uc-pxx-boot-ok
T=$(mktemp -d)
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
cleanup() { [ -s "$T/run/uc-pxx-boot-ok.pid" ] && kill "$(cat "$T/run/uc-pxx-boot-ok.pid")" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/run" "$T/etc"
for t in setsid; do command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED: $t is not installed"; exit 0; }; done

echo "== the script =="
busybox sh -n "$INIT" 2>/dev/null || sh -n "$INIT" && ok "the init script passes sh -n" || bad "syntax"
head -n 1 "$INIT" | grep -qx '#!/sbin/openrc-run' && ok "the init script is an OpenRC script" || bad "no openrc-run line"
[ -x "$INIT" ] && ok "the init script is executable" || bad "not executable"
grep -qx 'depend() { after sshd networking; }' "$INIT" && ok "it starts after sshd and networking" || bad "the depend() line changed"
grep -qx 'hook=/etc/uc-pxx-mark-boot.sh' "$INIT" && ok "the hook is /etc/uc-pxx-mark-boot.sh" || bad "another hook path"
c=$(grep -v '^[[:space:]]*#' "$INIT" | grep -cE 'start-stop-daemon|supervise-daemon|^[[:space:]]*(command|command_background|supervisor|pidfile)=')
[ "$c" = 0 ] && ok "no start-stop-daemon record (that record shows \"crashed\" after the hook ends)" || bad "the service gives the hook to a daemon tool"
c=$(grep -c '^[[:space:]]*setsid ' "$INIT")
[ "$c" = 1 ] && grep -q '^	setsid "$hook" < /dev/null > /dev/null 2>&1 &$' "$INIT" && ok "one line starts the hook (setsid, in the background, no input or output)" || bad "the start line of the hook changed"

# the copy: /run and the hook path in $T, stub OpenRC functions
sed -e "s#/run/#$T/run/#g" -e "s#/etc/uc-pxx-mark-boot.sh#$T/etc/uc-pxx-mark-boot.sh#g" "$INIT" > "$T/init"
cat > "$T/etc/uc-pxx-mark-boot.sh" <<EOF
#!/bin/sh
echo "run \$\$" >> "$T/runs"
sleep "\$(cat "$T/secs")"
echo end >> "$T/runs"
exit 1
EOF
chmod 755 "$T/etc/uc-pxx-mark-boot.sh"
svc() {
	sh -c 'ebegin() { :; }; eend() { return "$1"; }; ewarn() { echo "warn: $*" >&2; }
		. "$1"; "$2"' sh "$T/init" "$1" 2>> "$T/warn"
}
runs() { grep -c '^run' "$T/runs" 2>/dev/null || echo 0; }
pid() { cat "$T/run/uc-pxx-boot-ok.pid" 2>/dev/null; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
# wait_for N CMD...: up to N tenths of a second until CMD is true
wait_for() { i=0; n=$1; shift; until "$@"; do [ $i -ge "$n" ] && return 1; sleep 0.1; i=$((i + 1)); done; }
ended() { grep -qx end "$T/runs" 2>/dev/null; }
newboot() { rm -f "$T/run/"* "$T/runs" "$T/warn"; echo "$1" > "$T/secs"; }

echo "== start and stop =="
newboot 30
t0=$(cut -d' ' -f1 /proc/uptime)
svc start; rc=$?
t1=$(cut -d' ' -f1 /proc/uptime)
fast=$(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a < 2) ? 1 : 0 }')
{ [ $rc = 0 ] && [ "$fast" = 1 ]; } && ok "start returns at once (0) while the hook still runs" || bad "start: rc $rc, $t0 -> $t1"
wait_for 20 grep -qs '^run' "$T/runs" && [ "$(runs)" = 1 ] && ok "the hook runs once" || bad "hook runs: $(runs)"
p=$(pid)
{ alive "$p" && grep -qs "$T/etc/uc-pxx-mark-boot.sh" "/proc/$p/cmdline"; } && ok "the pid file holds the pid of the hook" || bad "pid file $p: $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
[ "$(cut -d' ' -f6 "/proc/$p/stat" 2>/dev/null)" = "$p" ] && ok "the hook runs in its own session (setsid)" || bad "the hook is not a session leader"
[ "$(readlink "/proc/$p/fd/0")" = /dev/null ] && [ "$(readlink "/proc/$p/fd/1")" = /dev/null ] && ok "stdin and stdout of the hook are /dev/null" || bad "the hook has other stdin or stdout"
svc start; rc=$?
{ [ $rc = 0 ] && [ "$(runs)" = 1 ] && grep -q 'does not start again' "$T/warn"; } && ok "a second start does not start the hook again" || bad "second start: rc $rc, runs $(runs)"
svc stop; rc=$?
{ [ $rc = 0 ] && wait_for 20 eval '! alive "$p"'; } && ok "stop ends the running hook (0)" || bad "stop: rc $rc, hook alive"
[ -e "$T/run/uc-pxx-boot-ok.pid" ] && ok "stop keeps the pid file" || bad "stop removed the pid file"
svc start; svc stop; svc start; rc=$?
{ [ $rc = 0 ] && [ "$(runs)" = 1 ]; } && ok "start after stop (a restart) does not start the hook again" || bad "restart: rc $rc, runs $(runs)"

echo "== the hook ends by itself =="
newboot 0
svc start; rc=$?
{ [ $rc = 0 ] && wait_for 50 ended && [ "$(runs)" = 1 ]; } && ok "the hook ends (here with 1), start gave 0" || bad "rc $rc, runs $(runs)"
svc start; [ "$(runs)" = 1 ] && ok "start after the end of the hook does not start it again" || bad "runs $(runs)"
sleep 300 & other=$!
echo "$other" > "$T/run/uc-pxx-boot-ok.pid"
svc stop; rc=$?
{ [ $rc = 0 ] && alive "$other"; } && ok "stop does not end another program with the old pid" || bad "stop ended pid $other (rc $rc)"
kill "$other" 2>/dev/null
newboot 0
svc stop; rc=$?
[ $rc = 0 ] && ok "stop without a pid file gives 0" || bad "stop without a pid file: rc $rc"

echo "== no hook =="
newboot 0
mv "$T/etc/uc-pxx-mark-boot.sh" "$T/hook.away"
svc start; rc=$?
{ [ $rc = 1 ] && [ ! -e "$T/run/uc-pxx-boot-ok.pid" ]; } && ok "start without the hook fails (1), no pid file" || bad "start without the hook: rc $rc"
mv "$T/hook.away" "$T/etc/uc-pxx-mark-boot.sh"
svc start; rc=$?
{ [ $rc = 0 ] && wait_for 50 ended && [ "$(runs)" = 1 ]; } && ok "the next start with the hook runs it" || bad "start after the hook is back: rc $rc, runs $(runs)"

echo "$N ok, $F failed"
[ "$F" = 0 ]
