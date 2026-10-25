#!/bin/sh
# Host test of the two board hooks with the real tsx-autoupdate. It needs no
# panel. tsx-autoupdate comes from TSX_COMMON (a checkout; the default is
# ../tsx-linux-common next to the repository). Without it, or with a
# tsx-autoupdate that has no tsx_board_post_update, the test prints SKIPPED.
#   - a copy of board.sh and of uc-pxx-post-update whose programs are stubs:
#     uc-pxx-arm-slot, uc-pxx-update-boot and uc-pxx-bootctl, and a made-up
#     list of the reviewed files
#   - a fake apk, and stubs for reboot, rc-service, curl and hostname
#   - the order of the calls: arm, apk upgrade, write of boot_a, A/B check,
#     restart. No restart after a failed write. A new try, a hold and the
#     command tsx-autoupdate post-update.
# The test never runs as root: a reboot stub that a shell ignores (a busybox
# that prefers its own applets) must not restart the host.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/.." && pwd)
COMMON=${TSX_COMMON:-$REPO/../tsx-linux-common}
BIN=$COMMON/autoupdate/usr/local/sbin/tsx-autoupdate
BOARD=$HERE/overlay/usr/local/lib/tsx/board.sh
PU=$HERE/overlay/usr/sbin/uc-pxx-post-update
if [ ! -f "$BIN" ] || ! grep -q tsx_board_post_update "$BIN"; then
	echo "SKIPPED: no tsx-autoupdate with tsx_board_post_update in $COMMON (set TSX_COMMON)"
	exit 0
fi
if [ "$(id -u)" = 0 ]; then
	echo "SKIPPED: this test does not run as root"
	exit 0
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

mkdir -p "$T/bin"
# Every stub writes one line to $T/order, in the order of the calls.
stub() {  # stub NAME LINE EXIT_CODE_FILE [LIST]: LIST is the file of the call lines (default order)
	printf '#!/bin/sh\necho "%s" >> "%s/%s"\necho "%s-stub $*"\nrc=$(cat "%s" 2>/dev/null)\nexit "${rc:-0}"\n' "$2" "$T" "${4:-order}" "$1" "$3" > "$T/bin/$1"
	chmod +x "$T/bin/$1"
}
stub arm-slot ARM "$T/arm.rc"
stub update-boot UB "$T/ub.rc"
stub reboot REBOOT /dev/null
for c in rc-service curl hostname; do stub "$c" "$c" /dev/null other; done
printf '#!/bin/sh\necho BC >> "%s/order"\n[ "$1" = status ] || exit 9\ncat "%s/ab.txt"\nrc=$(cat "%s/bc.rc" 2>/dev/null)\nexit "${rc:-0}"\n' "$T" "$T" "$T" > "$T/bin/bootctl"
chmod +x "$T/bin/bootctl"
cat > "$T/bin/apk" <<EOF
#!/bin/sh
case "\$1 \${2:-}" in
"update ") exit 0;;
"upgrade --simulate") cat "$T/sim.txt"; exit 0;;
"upgrade ") echo APK >> "$T/order"; : > "$T/sim.txt"; exit "\$(cat "$T/apk.rc" 2>/dev/null || echo 0)";;
"info -v") printf 'uc-pxx-board-0.1.0-r1\ntsx-base-0.3.12-r0\nuc-pxx-kernel-lts-6.18.54_git20261025-r1\n'; exit 0;;
esac
exit 0
EOF
chmod +x "$T/bin/apk"

# The shell for tsx-autoupdate: one that runs the reboot stub of PATH.
SH=
for s in "busybox sh" sh; do
	got=$(PATH="$T/bin:$PATH" $s -c 'command -v reboot' 2>/dev/null)
	[ "$got" = "$T/bin/reboot" ] && { SH=$s; break; }
done
if [ -z "$SH" ]; then
	echo "SKIPPED: no shell here runs the reboot stub of PATH"
	exit 0
fi
echo "shell for tsx-autoupdate: $SH"

sha256sum "$T/bin/update-boot" "$T/bin/arm-slot" > "$T/list"
sed -e "s|^LIST=/usr/share/uc-pxx/boot-control.sha256 ARM=/usr/sbin/uc-pxx-arm-slot TOOL=/usr/sbin/uc-pxx-update-boot BOOTCTL=/usr/sbin/uc-pxx-bootctl\$|LIST=$T/list ARM=$T/bin/arm-slot TOOL=$T/bin/update-boot BOOTCTL=$T/bin/bootctl|" \
	-e "s|^TOOL_SHA=.*|TOOL_SHA=$(sha256sum "$T/bin/update-boot" | cut -c1-64)|" "$PU" > "$T/bin/post-update"
chmod +x "$T/bin/post-update"
sed -e "s|/usr/sbin/uc-pxx-arm-slot;|$T/bin/arm-slot;|" -e "s|/usr/sbin/uc-pxx-post-update;|$T/bin/post-update;|" "$BOARD" > "$T/board.sh"
[ "$(grep -c "$T/bin/" "$T/board.sh")" = 2 ] && grep -q "^LIST=$T/list" "$T/bin/post-update" && ok "the stub copies of board.sh and uc-pxx-post-update" || bad "the stub copies: a path did not change"
printf 'MODE=manual\nAUTO_RESTART=on\n' > "$T/autoupdate.conf"
TRYING='uc-pxx-bootctl: current: A{prio 15 tries 7 succ 0} B{prio 14 tries 0 succ 1} crc 0
libavb-would-boot: a'
GOOD='uc-pxx-bootctl: current: A{prio 15 tries 0 succ 1} B{prio 14 tries 0 succ 1} crc 0
libavb-would-boot: a'

run() {
	PATH="$T/bin:$PATH" TSX_BOARD_CONF="$T/board.sh" TSX_AUTOUPDATE_CONF="$T/autoupdate.conf" \
	TSX_AUTOUPDATE_OVERRIDE="$T/none" TSX_BOOT_ID_FILE="$T/bootid" TSX_RUN_DIR="$T/run" TSX_STATE_DIR="$T/state" \
	TSX_LOG="$T/log" TSX_IDLED_STATE="$T/idled" TSX_KIOSK_CONF="$T/none" TSX_BUILD_ID_FILE="$T/none" \
	TSX_INITD="$T/none" TSX_BACKLIGHT_CLASS="$T/none" TSX_RUNLEVELS="$T/none" $SH "$BIN" "$@"
}
field() { sed -n "s/^$1 //p" "$T/state/fields"; }
order() { tr '\n' ' ' < "$T/order" 2>/dev/null | sed 's/ $//'; }
# start TOOL_RC: a fresh state with the kernel package pending
start() {
	rm -rf "$T/state" "$T/run" "$T/order" "$T/log"
	echo "boot-$$-$1" > "$T/bootid"
	printf '(1/1) Upgrading uc-pxx-kernel-lts (6.18.54_git20261025-r0 -> 6.18.54_git20261025-r1)\n' > "$T/sim.txt"
	echo 0 > "$T/arm.rc"; echo 0 > "$T/apk.rc"; echo "$1" > "$T/ub.rc"; echo 0 > "$T/bc.rc"
	printf '%s\n' "$TRYING" > "$T/ab.txt"
}

echo "== a kernel update: arm, apk upgrade, arm, write boot_a, check, restart =="
start 0
run now >/dev/null
eq "$(order)" "ARM APK ARM UB BC REBOOT" "the order of the calls"
eq "$(field post_update)/$(field last_result)" "/ok" "nothing open, last_result ok"
grep -q 'update-boot-stub write --yes' "$T/log" && ok "the output of uc-pxx-update-boot is in the log" || bad "no output of uc-pxx-update-boot in the log"

echo "== the tool exits 1: no restart, Install tries again =="
start 1
run now >/dev/null
eq "$(order)" "ARM APK ARM UB" "no A/B check and no restart after status 1"
eq "$(field post_update)/$(field last_result)" "retry 1/post-update hook rc=1" "retry state"
: > "$T/order"; echo 11 > "$T/ub.rc"
run now >/dev/null
eq "$(order)" "ARM UB" "a new try runs only uc-pxx-post-update: arm, then the tool (11)"
eq "$(field post_update)" "retry 1" "11 is a retry too"
: > "$T/order"; echo 0 > "$T/ub.rc"
run now >/dev/null
eq "$(order)" "ARM UB BC REBOOT" "the new try works: arm, write, check, restart"
eq "$(field post_update)" "" "nothing open after the new try"

echo "== the tool exits 21 (boot_a may be partial): held =="
start 21
run now >/dev/null
eq "$(order)" "ARM APK ARM UB" "no restart after 21"
eq "$(field post_update)" "hold 21" "held"
: > "$T/order"; echo 0 > "$T/ub.rc"
printf '(1/1) Upgrading uc-pxx-board (0.1.0-r1 -> 0.1.0-r2)\n' > "$T/sim.txt"
run now >/dev/null
eq "$(order)" "" "Install while held: no arm, no apk upgrade, no write, no restart"
out=$(run post-update); rc=$?
eq "$rc/$(order)" "0/ARM UB BC" "post-update by hand: arm, the tool and the check, no restart"
case $out in *"update-boot-stub write --yes"*) ok "post-update shows the output of the tool";; *) bad "post-update output: $out";; esac
eq "$(field post_update)/$(field restart_required)" "/1" "the hold ended, restart required"
: > "$T/order"; : > "$T/sim.txt"
run now >/dev/null
eq "$(order)" "REBOOT" "Install restarts after the step"

echo "== the other statuses of the tool hold =="
for rc in 13 23 24 29 30; do
	start "$rc"
	run now >/dev/null
	eq "$(order)/$(field post_update)" "ARM APK ARM UB/hold $rc" "tool $rc: no restart, held"
done

echo "== hold 24 (boot_a new, slot A not re-armed): post-update re-arms and the restart keeps the fallback =="
start 24
printf '%s\n' "$GOOD" > "$T/ab.txt"
run now >/dev/null
eq "$(field post_update)" "hold 24" "held with 24"
# the stub arm-slot does not change ab.txt, so set the state that a real arm leaves
: > "$T/order"; echo 0 > "$T/ub.rc"; printf '%s\n' "$TRYING" > "$T/ab.txt"
out=$(run post-update); rc=$?
eq "$rc/$(order)/$(field post_update)" "0/ARM UB BC/" "post-update: arm first, the tool is a no-op, the check passes"

echo "== C14b: hold 13, then post-update with an arm that refuses =="
start 13
run now >/dev/null
eq "$(field post_update)" "hold 13" "held with 13"
# the arm refuses and the A/B state reads as valid: the step exits 1, the hold stays
: > "$T/order"; echo 1 > "$T/arm.rc"
run post-update >/dev/null 2>&1
eq "$(order)/$(field post_update)/$(cat "$T/run/restart-block" 2>/dev/null)" "ARM BC/hold 13/hold 13" "arm 1, valid A/B state: the hold 13 and the block stay"
# the arm refuses and uc-pxx-bootctl status fails too (an invalid sector): 40, still held
: > "$T/order"; echo 1 > "$T/bc.rc"
run post-update >/dev/null 2>&1
eq "$(order)/$(field post_update)/$(cat "$T/run/restart-block" 2>/dev/null)" "ARM BC/hold 40/hold 40" "arm 1, unreadable A/B state: hold 40, the block stays"
echo 0 > "$T/arm.rc"; echo 0 > "$T/bc.rc"; echo 0 > "$T/ub.rc"; : > "$T/order"
run post-update >/dev/null 2>&1
eq "$(order)/$(field post_update)" "ARM UB BC/" "a good post-update ends the hold"
[ -e "$T/run/restart-block" ] && bad "the block stays after the hold ended" || ok "the block is gone after the hold ended"

echo "== the A/B state does not allow a restart: held (40) =="
start 0
printf '%s\n' "$GOOD" > "$T/ab.txt"
run now >/dev/null
eq "$(order)/$(field post_update)" "ARM APK ARM UB BC/hold 40" "slot A successful after the write: no restart"

echo "== a changed reviewed file: held (41), nothing armed or written after the upgrade =="
start 0
cp "$T/list" "$T/list.good"; sed -i 's/^\(.\)/0/' "$T/list"
run now >/dev/null
eq "$(order)/$(field post_update)" "ARM APK/hold 41" "41: the post step armed nothing and wrote nothing"
cp "$T/list.good" "$T/list"

echo "== uc-pxx-arm-slot refuses before the upgrade: nothing else runs =="
start 0
echo 1 > "$T/arm.rc"
run now >/dev/null
eq "$(order)/$(field post_update)/$(field last_result)" "ARM//pre-update hook rc=1" "no apk upgrade, no write"

echo "== one run at a time: a held lock skips Install =="
start 0
mkdir -p "$T/run"
( flock -x 9; sleep 3 ) 9>"$T/run/autoupdate.lock" &
LP=$!; sleep 0.5
run now >/dev/null
eq "$(order)" "" "Install while another run holds the lock: nothing runs"
grep -q 'another tsx-autoupdate run is active' "$T/log" && ok "the skip is in the log" || bad "no log line for the skip"
wait "$LP"
run now >/dev/null
eq "$(order)" "ARM APK ARM UB BC REBOOT" "after the lock is free: the install runs"

echo "$N passed, $F failed"
[ "$F" = 0 ]
