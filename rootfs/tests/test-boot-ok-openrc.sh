#!/bin/sh
# Test of the service uc-pxx-boot-ok under a real OpenRC, in an Alpine
# container. The service starts a stub hook, and the test reads the state
# that rc-service and rc-status show.
#   sh rootfs/tests/test-boot-ok-openrc.sh [INIT_SCRIPT]
# On the host the script starts itself in a container (docker, the image
# UC_PXX_TEST_IMAGE, default alpine:3.24) and installs openrc there (network).
# Without docker it prints SKIPPED and exits 0. INIT_SCRIPT (a path in this
# repository) replaces rootfs/overlay/etc/init.d/uc-pxx-boot-ok.
set -u
if [ "${1:-}" != --in-container ]; then
	HERE=$(cd "$(dirname "$0")/../.." && pwd)
	command -v docker >/dev/null 2>&1 || { echo "SKIPPED: docker is not installed"; exit 0; }
	init=${1:-rootfs/overlay/etc/init.d/uc-pxx-boot-ok}
	exec docker run --rm -v "$HERE:/src:ro" "${UC_PXX_TEST_IMAGE:-alpine:3.24}" \
		sh /src/rootfs/tests/test-boot-ok-openrc.sh --in-container "/src/$init"
fi
# In the container. The test writes /etc/init.d and /etc/uc-pxx-mark-boot.sh,
# so it refuses to run anywhere else.
[ -e /.dockerenv ] || { echo "FAIL: not in a container"; exit 1; }
[ ! -e /etc/uc-pxx-mark-boot.sh ] || { echo "FAIL: /etc/uc-pxx-mark-boot.sh exists, this is not a test system"; exit 1; }
INIT=$2
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
apk add --no-cache -q openrc >/dev/null || { echo "FAIL: apk add openrc"; exit 1; }
echo "openrc $(apk info -e -v openrc 2>/dev/null), $(cat /etc/alpine-release)"
mkdir -p /run/openrc; touch /run/openrc/softlevel
install -m 755 "$INIT" /etc/init.d/uc-pxx-boot-ok
# the stub hook: one line for each run, a line on SIGTERM, then it ends with the code in /tmp/hook.rc
cat > /etc/uc-pxx-mark-boot.sh <<'EOF'
#!/bin/sh
trap 'echo term >> /tmp/hook.log; exit 143' TERM
echo "run $$" >> /tmp/hook.log
sleep "$(cat /tmp/hook.secs)" & wait $!
echo end >> /tmp/hook.log
exit "$(cat /tmp/hook.rc)"
EOF
chmod 755 /etc/uc-pxx-mark-boot.sh

state() { rc-service -C uc-pxx-boot-ok status 2>&1 | sed -n 's/.*status: //p'; }
crashed() { rc-status -C --crashed 2>/dev/null | grep -qw uc-pxx-boot-ok; }
runs() { grep -c '^run' /tmp/hook.log 2>/dev/null || echo 0; }
wait_for() { i=0; n=$1; shift; until "$@"; do [ $i -ge "$n" ] && return 1; sleep 0.1; i=$((i + 1)); done; }
ended() { grep -qx end /tmp/hook.log 2>/dev/null; }
hookpid() { cat /run/uc-pxx-boot-ok.pid 2>/dev/null; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
now() { cut -d' ' -f1 /proc/uptime; }
lt() { awk -v a="$1" -v b="$2" -v m="$3" 'BEGIN { exit !(b - a < m) }'; }
# newboot SECS RC: the state of a new boot (empty /run, service stopped)
newboot() {
	rc-service -C uc-pxx-boot-ok zap >/dev/null 2>&1
	rm -f /run/uc-pxx-boot-ok.pid /tmp/hook.log
	echo "$1" > /tmp/hook.secs; echo "$2" > /tmp/hook.rc
}

echo "== the boot: openrc default =="
rc-update -q add uc-pxx-boot-ok default
newboot 4 0
t0=$(now); timeout 60 openrc -q default >/dev/null 2>&1; rc=$?; t1=$(now)
{ [ $rc = 0 ] && lt "$t0" "$t1" 3; } && ok "openrc default returns at once ($t0 -> $t1) while the hook runs" || bad "openrc default: rc $rc, $t0 -> $t1"
[ "$(state)" = started ] && ok "while the hook runs: started" || bad "while the hook runs: $(state)"
wait_for 100 ended && ok "the hook ends with 0" || bad "the hook did not end"
sleep 0.5
{ [ "$(state)" = started ] && ! crashed; } && ok "after the hook ends: started, not in rc-status --crashed" || bad "after the hook ends: $(state)"
rc-status default 2>/dev/null | grep uc-pxx-boot-ok | sed 's/^/    rc-status: /'
[ "$(runs)" = 1 ] && ok "one run" || bad "runs: $(runs)"
rc-service -C uc-pxx-boot-ok restart >/dev/null 2>&1; rc=$?
sleep 0.5
{ [ $rc = 0 ] && [ "$(runs)" = 1 ] && [ "$(state)" = started ]; } && ok "restart: started, the hook does not run again" || bad "restart: rc $rc, runs $(runs), $(state)"
rc-service -C uc-pxx-boot-ok stop >/dev/null 2>&1; s1=$(state)
rc-service -C uc-pxx-boot-ok start >/dev/null 2>&1; s2=$(state)
sleep 0.5
{ [ "$s1" = stopped ] && [ "$s2" = started ] && [ "$(runs)" = 1 ]; } && ok "stop, start: stopped, started, no second run" || bad "stop, start: $s1, $s2, runs $(runs)"
rc-update -q del uc-pxx-boot-ok default

echo "== the hook ends with 1 =="
newboot 1 1
rc-service -C uc-pxx-boot-ok start >/dev/null 2>&1; rc=$?
wait_for 50 ended; sleep 0.5
{ [ $rc = 0 ] && [ "$(state)" = started ] && ! crashed; } && ok "start gives 0, the state stays started (the hook logs its result)" || bad "rc $rc, $(state)"

echo "== stop while the hook runs =="
newboot 30 0
rc-service -C uc-pxx-boot-ok start >/dev/null 2>&1
wait_for 50 grep -qs '^run' /tmp/hook.log
p=$(hookpid)
{ alive "$p" && grep -qs /etc/uc-pxx-mark-boot.sh "/proc/$p/cmdline"; } && ok "the pid file holds the pid of the hook ($p)" || bad "pid file: $p"
[ "$(cut -d' ' -f6 "/proc/$p/stat" 2>/dev/null)" = "$p" ] && ok "the hook runs in its own session" || bad "the hook is not a session leader"
t0=$(now); timeout 20 rc-service -C uc-pxx-boot-ok stop >/dev/null 2>&1; rc=$?; t1=$(now)
{ [ $rc = 0 ] && lt "$t0" "$t1" 3; } && ok "stop returns at once" || bad "stop: rc $rc, $t0 -> $t1"
{ wait_for 30 eval '! alive "$p"' && grep -qx term /tmp/hook.log && [ "$(state)" = stopped ]; } && ok "the hook got SIGTERM and ended, the state is stopped" || bad "after stop: $(state), $(tr '\n' ' ' < /tmp/hook.log)"
rc-service -C uc-pxx-boot-ok start >/dev/null 2>&1
sleep 0.5
{ [ "$(state)" = started ] && [ "$(runs)" = 1 ]; } && ok "start after the stop: started, no second run" || bad "start after stop: $(state), runs $(runs)"

echo "== the pid of an ended hook belongs to another program =="
newboot 0 0
rc-service -C uc-pxx-boot-ok start >/dev/null 2>&1
wait_for 50 ended
sleep 300 & other=$!
echo "$other" > /run/uc-pxx-boot-ok.pid
rc-service -C uc-pxx-boot-ok stop >/dev/null 2>&1; rc=$?
{ [ $rc = 0 ] && alive "$other"; } && ok "stop does not end the other program" || bad "stop ended pid $other (rc $rc)"
kill "$other" 2>/dev/null

echo "== no hook =="
newboot 0 0
mv /etc/uc-pxx-mark-boot.sh /tmp/hook.away
rc-service -C uc-pxx-boot-ok start >/dev/null 2>&1; rc=$?
{ [ $rc != 0 ] && [ "$(state)" != started ] && [ ! -e /run/uc-pxx-boot-ok.pid ]; } && ok "start without the hook fails ($rc), the state is $(state)" || bad "start without the hook: rc $rc, $(state)"
mv /tmp/hook.away /etc/uc-pxx-mark-boot.sh

echo "$N ok, $F failed"
[ "$F" = 0 ]
