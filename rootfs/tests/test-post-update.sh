#!/bin/sh
# Host test of /usr/sbin/uc-pxx-post-update (rootfs/overlay/usr/sbin). It needs no panel. A copy of the script
# gets stubs in place of its four fixed paths (the list of the reviewed files, uc-pxx-arm-slot,
# uc-pxx-update-boot, uc-pxx-bootctl) and the sha256 of the stub tool in place of TOOL_SHA.
#   - the order: the file check, the arm, the tool, the A/B check. Nothing runs after a failed step.
#   - the exit status for each status of the arm and of the tool, and for each A/B state
#   - a changed reviewed file or another tool sha: 41, nothing armed or written
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$HERE/overlay/usr/sbin/uc-pxx-post-update
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== the script =="
busybox sh -n "$SCRIPT" 2>/dev/null && ok "busybox sh -n" || bad "busybox sh -n"
[ -x "$SCRIPT" ] && ok "executable" || bad "not executable"
grep -q '^TOOL_SHA=4de04b78b8a48a4cf4d79f22f18f2f69a6932a36398e4ba6ec0ac175483b3703$' "$SCRIPT" && ok "TOOL_SHA is the reviewed uc-pxx-update-boot" || bad "TOOL_SHA is not 4de04b78..."
grep -q '^LIST=/usr/share/uc-pxx/boot-control.sha256 ARM=/usr/sbin/uc-pxx-arm-slot TOOL=/usr/sbin/uc-pxx-update-boot BOOTCTL=/usr/sbin/uc-pxx-bootctl$' "$SCRIPT" && ok "the fixed paths" || bad "the paths line changed"
grep -Eq '\bof=|dd |bootctl"? (arm-trying|mark-successful)|> */dev/mmc' "$SCRIPT" && bad "the script writes or arms by itself" || ok "the script writes nothing by itself"
eq "$(grep -c 'timeout -s KILL 30 "\$BOOTCTL" status' "$SCRIPT")" 2 "both uc-pxx-bootctl status calls have timeout -s KILL 30"
grep -v '^#' "$SCRIPT" | grep 'BOOTCTL" status' | grep -vq 'timeout -s KILL 30' && bad "a uc-pxx-bootctl status without timeout -s KILL" || ok "no uc-pxx-bootctl status without timeout -s KILL"

mkdir -p "$T/bin"
# Each stub writes one word to $T/order and exits with the number in its .rc file.
stub() {  # stub NAME WORD
	printf '#!/bin/sh\necho %s >> "%s/order"\necho "%s-stub $*"\nrc=$(cat "%s/%s.rc" 2>/dev/null)\nexit "${rc:-0}"\n' "$2" "$T" "$1" "$T" "$1" > "$T/bin/$1"
	chmod +x "$T/bin/$1"
}
stub arm ARM
stub tool UB
printf '#!/bin/sh\necho BC >> "%s/order"\n[ "$1" = status ] || exit 9\ncat "%s/ab.txt"\nexit "$(cat "%s/bc.rc")"\n' "$T" "$T" "$T" > "$T/bin/bootctl"
chmod +x "$T/bin/bootctl"
echo pinned > "$T/pinned"
sha256sum "$T/pinned" "$T/bin/tool" > "$T/list"
TSHA=$(sha256sum "$T/bin/tool" | cut -c1-64)
sed -e "s|^LIST=/usr/share/uc-pxx/boot-control.sha256 ARM=/usr/sbin/uc-pxx-arm-slot TOOL=/usr/sbin/uc-pxx-update-boot BOOTCTL=/usr/sbin/uc-pxx-bootctl\$|LIST=$T/list ARM=$T/bin/arm TOOL=$T/bin/tool BOOTCTL=$T/bin/bootctl|" \
	-e "s|^TOOL_SHA=.*|TOOL_SHA=$TSHA|" "$SCRIPT" > "$T/pu"
grep -q "^LIST=$T/list" "$T/pu" && grep -q "^TOOL_SHA=$TSHA" "$T/pu" && ok "the stub copy" || bad "the stub copy: a line did not change"
ab() { printf 'uc-pxx-bootctl: current: %s crc 0\nlibavb-would-boot: %s\n' "$1" "${2:-a}" > "$T/ab.txt"; echo "${3:-0}" > "$T/bc.rc"; }
run() {  # run ARM_RC TOOL_RC: print "ORDER/status"
	echo "$1" > "$T/arm.rc"; echo "$2" > "$T/tool.rc"; : > "$T/order"
	sh "$T/pu" > "$T/out" 2>&1; rc=$?
	echo "$(tr '\n' ' ' < "$T/order" | sed 's/ $//')/$rc"
}
TRY='A{prio 15 tries 7 succ 0} B{prio 14 tries 0 succ 1}'

echo "== a good run: check, arm, write, A/B check =="
ab "$TRY"
eq "$(run 0 0)" "ARM UB BC/0" "the order, status 0"
grep -q '^tool-stub write --yes$' "$T/out" && ok "the tool runs with write --yes" || bad "the tool arguments"
grep -q "$T/pinned: OK" "$T/out" && ok "the output of sha256sum -c is shown" || bad "no sha256sum -c output"
for b in 1 9 10 14; do
	ab "A{prio 15 tries 7 succ 0} B{prio $b tries 0 succ 1}"; eq "$(run 0 0)" "ARM UB BC/0" "slot B with priority $b: 0"
done

echo "== the restart check refuses: 40 =="
for st in 'A{prio 15 tries 7 succ 0} B{prio 15 tries 0 succ 1}' 'A{prio 15 tries 7 succ 0} B{prio 0 tries 0 succ 1}' \
	'A{prio 15 tries 7 succ 0} B{prio 14 tries 1 succ 0}' 'A{prio 15 tries 6 succ 0} B{prio 14 tries 0 succ 1}' \
	'A{prio 15 tries 0 succ 1} B{prio 14 tries 0 succ 1}' 'A{prio 14 tries 7 succ 0} B{prio 14 tries 0 succ 1}'; do
	ab "$st"; eq "$(run 0 0)" "ARM UB BC/40" "$st: 40"
done
ab "$TRY" b; eq "$(run 0 0)" "ARM UB BC/40" "the next boot would start slot B: 40"
ab "$TRY" a 3; eq "$(run 0 0)" "ARM UB BC/40" "uc-pxx-bootctl status fails: 40"
grep -q 'Do NOT restart' "$T/out" && ok "40 says do not restart" || bad "40 without the warning"
printf 'uc-pxx-bootctl: current: A{prio 15 tries 7 succ 0} B{prio 14 tries 0 succ 1} crc 0\n' > "$T/ab.txt"; echo 0 > "$T/bc.rc"
eq "$(run 0 0)" "ARM UB BC/40" "no libavb-would-boot line: 40"

echo "== the arm step: 1 tries again later (A/B state valid), every other status holds, the tool does not run =="
ab "$TRY"
eq "$(run 1 0)" "ARM BC/1" "arm 1 and a valid A/B state: 1, no write"
ab 'A{prio 15 tries 0 succ 1} B{prio 14 tries 0 succ 1}'
eq "$(run 1 0)" "ARM BC/1" "arm 1 (for example the A/B lock was busy), A successful: 1"
# C14b of the review: bootctl refuses an invalid sector, so arm-slot exits 1 and status fails too
ab "$TRY" a 1
eq "$(run 1 0)" "ARM BC/40" "arm 1 and uc-pxx-bootctl status fails (an invalid sector): 40, a hold"
grep -q 'the A/B state needs a person' "$T/out" && ok "40 after the arm says that the A/B state needs a person" || bad "40 after the arm: text"
ab "$TRY" a 3
eq "$(run 1 0)" "ARM BC/40" "arm 1 and uc-pxx-bootctl status exit 3: 40"
ab "$TRY"
eq "$(run 3 0)" "ARM/13" "arm 3 (A/B state unknown): 13"
eq "$(run 2 0)" "ARM/12" "arm 2: 12"
eq "$(run 127 0)" "ARM/19" "arm 127 (missing): 19"

echo "== the tool: 1 and 11 try again later, other statuses pass through, no A/B check after a failure =="
for rc in 1 11; do eq "$(run 0 $rc)" "ARM UB/1" "tool $rc: 1"; done
for rc in 2 13 19 21 23 24 29 30 127; do eq "$(run 0 $rc)" "ARM UB/$rc" "tool $rc: $rc"; done
grep -q 'Do NOT restart and do NOT switch off' "$T/out" && ok "a hold of the tool says do not restart or switch off" || bad "hold text"

echo "== the reviewed files: 41 before anything runs =="
echo changed > "$T/pinned"
eq "$(run 0 0)" "/41" "a changed reviewed file: 41, no arm, no write"
echo pinned > "$T/pinned"
eq "$(run 0 0)" "ARM UB BC/0" "the file again as reviewed: 0"
sed "s|^TOOL_SHA=.*|TOOL_SHA=4de04b78b8a48a4cf4d79f22f18f2f69a6932a36398e4ba6ec0ac175483b3703|" "$T/pu" > "$T/pu2"; mv "$T/pu2" "$T/pu"
eq "$(run 0 0)" "/41" "the tool is not the reviewed sha: 41, no arm, no write"
grep -q 'Nothing armed or written' "$T/out" && ok "41 says nothing was armed or written" || bad "41 text"

echo "== a hanging uc-pxx-bootctl status ends also with SIGTERM ignored (as under tsx-autoupdate) =="
# The copy waits 2 s, not 30 s. The stub hangs for 20 s.
sed -e 's/timeout -s KILL 30 /timeout -s KILL 2 /' -e "s|^TOOL_SHA=.*|TOOL_SHA=$TSHA|" "$T/pu" > "$T/pu-fast"
# exec: one process that hangs, as the static uc-pxx-bootctl would be
printf '#!/bin/sh\necho BC >> "%s/order"\nexec sleep 20\n' "$T" > "$T/bin/bootctl-hang"; chmod +x "$T/bin/bootctl-hang"
sed -i "s|BOOTCTL=$T/bin/bootctl\$|BOOTCTL=$T/bin/bootctl-hang|" "$T/pu-fast"
echo 0 > "$T/arm.rc"; echo 0 > "$T/tool.rc"; : > "$T/order"
t0=$(date +%s)
( trap '' TERM; sh "$T/pu-fast" > "$T/out" 2>&1 ); rc=$?
t1=$(date +%s)
eq "$rc" 40 "the hanging restart check: 40"
[ $((t1 - t0)) -lt 10 ] && ok "it ended after about 2 s ($((t1 - t0)) s), not after 20 s" || bad "it waited $((t1 - t0)) s"
echo 1 > "$T/arm.rc"; : > "$T/order"
t0=$(date +%s)
( trap '' TERM; sh "$T/pu-fast" > "$T/out" 2>&1 ); rc=$?
t1=$(date +%s)
eq "$rc" 40 "arm 1 and a hanging status read: 40"
[ $((t1 - t0)) -lt 10 ] && ok "it ended after about 2 s ($((t1 - t0)) s)" || bad "it waited $((t1 - t0)) s"

echo "$N passed, $F failed"
[ "$F" = 0 ]
