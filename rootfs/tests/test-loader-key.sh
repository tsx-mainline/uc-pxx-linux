#!/bin/sh
# Host test for the loader mode keys: the service uc-pxx-loader-key and the
# check in /init of the initramfs. It needs no panel: a made-up /sys/class/input,
# a stub for evtest (the exit code 10 means "key down") and a stub for
# uc-pxx-reboot. Run it with busybox sh.
#   - the device is the maXTouch controller, no other device
#   - both keys down for the hold time: uc-pxx-reboot loader runs once
#   - one key only, or a release before the end: no reboot
#   - /init: the same rule with a hold of 3 s, and no delay with no key down
#   - the device tree node and the reboot program
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/.." && pwd)
LK=$HERE/overlay/usr/local/sbin/uc-pxx-loader-key
INIT=$HERE/initramfs/overlay/init
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== files =="
busybox sh -n "$LK" && ok "uc-pxx-loader-key passes busybox sh -n" || bad "busybox sh -n"
busybox sh -n "$HERE/overlay/etc/init.d/uc-pxx-loader-key" && ok "the init script passes busybox sh -n" || bad "init script"
head -n 1 "$HERE/overlay/etc/init.d/uc-pxx-loader-key" | grep -qx '#!/sbin/openrc-run' && ok "the init script is an OpenRC script" || bad "no openrc-run line"
[ -x "$LK" ] && [ -x "$HERE/overlay/etc/init.d/uc-pxx-loader-key" ] && ok "both are executable" || bad "not executable"
grep -q 'KEY_MUTE' "$LK" && grep -q 'KEY_VOLUMEDOWN' "$LK" && ok "the keys are KEY_MUTE and KEY_VOLUMEDOWN" || bad "wrong keys"
grep -q '113' "$HERE/overlay/etc/tsx/buttons-board.conf" && grep -q '114' "$HERE/overlay/etc/tsx/buttons-board.conf" && ok "buttons-board.conf has the codes 113 (mic) and 114 (volume down)" || bad "buttons-board.conf"

# a made-up input tree: event0 = touch controller, event1 = gpio-keys
mkdir -p "$T/sys/event0/device" "$T/sys/event1/device" "$T/dev"
echo "Atmel maXTouch Touchscreen" > "$T/sys/event0/device/name"
echo "gpio-keys" > "$T/sys/event1/device/name"
# the stub: DEV EV_KEY KEY. It reads the files $T/down.<event>.<KEY> (key down)
cat > "$T/evtest" <<EOS
#!/bin/sh
# evtest --query DEV EV_KEY KEY
echo "\$3 \$4" >> "$T/evtest.calls"
[ -e "$T/down.\$(basename "\$2").\$4" ] && exit 10
exit 0
EOS
cat > "$T/reboot" <<EOS
#!/bin/sh
echo "\$*" >> "$T/reboot.calls"
EOS
chmod 755 "$T/evtest" "$T/reboot"
export UC_PXX_SYSINPUT=$T/sys UC_PXX_DEVINPUT=$T/dev UC_PXX_EVTEST=$T/evtest UC_PXX_REBOOT=$T/reboot UC_PXX_POLL_S=0.2 UC_PXX_ONCE=1
reboots() { cat "$T/reboot.calls" 2>/dev/null | wc -l | tr -d ' '; }
reset() { rm -f "$T"/down.* "$T/reboot.calls" "$T/evtest.calls"; }

echo "== the service loop (hold 2 s in the test) =="
eq "$(UC_PXX_SYSINPUT=$T/sys busybox sh "$LK" --probe; echo $?)" 0 "--probe: the touch controller is found"
eq "$(UC_PXX_SYSINPUT=$T/nothing busybox sh "$LK" --probe; echo $?)" 1 "--probe: no device, exit 1"
reset; touch "$T/down.event0.KEY_MUTE" "$T/down.event0.KEY_VOLUMEDOWN"
UC_PXX_HOLD_S=2 timeout 8 busybox sh "$LK" > "$T/out" 2>&1
eq "$(cat "$T/reboot.calls")" "loader" "both keys down for the hold time: uc-pxx-reboot loader"
grep -q 'restarting into the loader mode' "$T/out" && ok "and it logs the reason" || bad "no log line"
reset; touch "$T/down.event0.KEY_VOLUMEDOWN"
UC_PXX_HOLD_S=1 timeout 4 busybox sh "$LK" > "$T/out" 2>&1
eq "$(reboots)" 0 "Volume down alone: no reboot"
reset; touch "$T/down.event0.KEY_MUTE"
UC_PXX_HOLD_S=1 timeout 4 busybox sh "$LK" > "$T/out" 2>&1
eq "$(reboots)" 0 "Mute alone: no reboot"
reset; touch "$T/down.event1.KEY_MUTE" "$T/down.event1.KEY_VOLUMEDOWN"
UC_PXX_HOLD_S=1 timeout 4 busybox sh "$LK" > "$T/out" 2>&1
eq "$(reboots)" 0 "both keys on another device (gpio-keys): no reboot"
reset; touch "$T/down.event0.KEY_MUTE" "$T/down.event0.KEY_VOLUMEDOWN"
( sleep 1; rm -f "$T"/down.event0.KEY_MUTE ) &
UC_PXX_HOLD_S=3 timeout 6 busybox sh "$LK" > "$T/out" 2>&1
wait
eq "$(reboots)" 0 "a key released before the hold time: no reboot"

echo "== /init: the check at the boot =="
# take the functions loader_dev, loader_held, loader_show, loader_check out of /init
sed -n '/^loader_dev() {/,/^loader_check$/p' "$INIT" | sed '$d' > "$T/funcs.sh"
[ -s "$T/funcs.sh" ] && ok "init has the loader check" || bad "no loader check in init"
grep -n '^loader_check$' "$INIT" > /dev/null && ok "init calls loader_check" || bad "init does not call loader_check"
cat > "$T/run-init.sh" <<EOS
msg() { echo "msg: \$*"; }
splash() { echo splash; }
SPLASH=/nonexistent
PATH=$T/bin:\$PATH
. "$T/funcs.sh"
loader_check
echo "returned"
EOS
mkdir -p "$T/bin"; cp "$T/evtest" "$T/bin/evtest"; cp "$T/reboot" "$T/uc-pxx-reboot"
# the real script calls /usr/sbin/uc-pxx-reboot and /usr/sbin/uc-pxx-reboot is tested with -x: use a rewritten copy
sed -e "s|/usr/sbin/uc-pxx-reboot|$T/uc-pxx-reboot|g" -e "s|/sys/class/input|$T/sys|; s|/dev/input|$T/dev|" "$T/funcs.sh" > "$T/funcs2.sh"
sed -i "s|funcs.sh|funcs2.sh|" "$T/run-init.sh"
sed -i 's|sleep 0.1|sleep 0.01|; s|sleep 0.2|sleep 0.02|' "$T/funcs2.sh"
reset
s=$(date +%s%N); busybox sh "$T/run-init.sh" > "$T/out" 2>&1; e=$(date +%s%N)
eq "$(reboots)" 0 "no key down: no reboot"
[ $(( (e - s) / 1000000 )) -lt 1500 ] && ok "and no delay ($(( (e - s) / 1000000 )) ms)" || bad "the check took $(( (e - s) / 1000000 )) ms"
reset; touch "$T/down.event0.KEY_MUTE" "$T/down.event0.KEY_VOLUMEDOWN"
busybox sh "$T/run-init.sh" > "$T/out" 2>&1
eq "$(cat "$T/reboot.calls" 2>/dev/null)" "loader" "both keys down: uc-pxx-reboot loader"
grep -q 'msg: Volume down + Mute held for 3 s' "$T/out" && ok "init logs the reason" || bad "no log: $(cat "$T/out")"
reset; touch "$T/down.event0.KEY_MUTE"
busybox sh "$T/run-init.sh" > "$T/out" 2>&1
eq "$(reboots)" 0 "Mute alone: no reboot"
grep -q '^returned$' "$T/out" && ok "and the boot goes on" || bad "the check did not return"
grep -q '3 s' "$INIT" && grep -q 'i -lt 15' "$INIT" && ok "init: 15 steps of 0.2 s are 3 s" || bad "init: wrong hold"

echo "== the device tree node and the reboot program =="
DT=$REPO/../linux-uc-pxx-6.18/arch/arm64/boot/dts/rockchip/rk3399-crestron-uc-pxx.dtsi
if [ -f "$DT" ]; then
	grep -q 'syscon-reboot-mode' "$DT" && grep -q 'mode-loader = <BOOT_BL_DOWNLOAD>' "$DT" && grep -q 'offset = <0x300>' "$DT" && ok "the dtsi has reboot-mode with mode-loader = BOOT_BL_DOWNLOAD at 0x300" || bad "no reboot-mode node in the dtsi"
else echo "  (no kernel checkout next to the repository: the dtsi check is skipped)"; fi
grep -q 'LINUX_REBOOT_CMD_RESTART2' "$REPO/tools/uc-pxx-reboot/uc-pxx-reboot-syscall.c" && ok "uc-pxx-reboot-syscall uses RESTART2" || bad "no RESTART2"
grep -q 'mmcblk' "$REPO/tools/uc-pxx-reboot/uc-pxx-reboot-syscall.c" "$LK" && bad "the loader code names the eMMC" || ok "the loader code does not touch the eMMC"

echo "$N passed, $F failed"
[ "$F" = 0 ]
