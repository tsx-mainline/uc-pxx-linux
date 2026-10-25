#!/bin/sh
# Host test for uc-pxx-reboot (the clean restart into the loader or fastboot
# mode). It needs no panel: a made-up /proc/1/cmdline and inittab, and stubs
# for reboot and uc-pxx-reboot-syscall. Run it with busybox sh.
#   - the arguments: loader and fastboot only
#   - PID 1 is busybox init with the shutdown line: the mode file, then reboot
#   - --pending: the mode file gives the argument of uc-pxx-reboot-syscall
#   - PID 1 is the /init script, or inittab has no shutdown line: at once
#   - the three inittab files have the shutdown line after the other shutdown line
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/.." && pwd)
RB=$HERE/overlay/usr/sbin/uc-pxx-reboot
HOOK='::shutdown:/usr/sbin/uc-pxx-reboot --pending'
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== the file =="
busybox sh -n "$RB" && ok "uc-pxx-reboot passes busybox sh -n" || bad "busybox sh -n"
[ -x "$RB" ] && ok "uc-pxx-reboot is executable" || bad "not executable"
head -n 1 "$RB" | grep -qx '#!/bin/sh' && ok "a /bin/sh script" || bad "wrong shebang"
grep -q 'mmcblk' "$RB" && bad "uc-pxx-reboot names the eMMC" || ok "uc-pxx-reboot does not touch the eMMC"

mkdir -p "$T/proc/1" "$T/run"
cat > "$T/syscall" <<EOS
#!/bin/sh
echo "\$*" >> "$T/syscall.calls"
EOS
# the reboot stub keeps the content of the mode file at the time of the call
cat > "$T/reboot" <<EOS
#!/bin/sh
cat "$T/run/uc-pxx-reboot.mode" >> "$T/reboot.calls" 2>/dev/null || echo "no mode file" >> "$T/reboot.calls"
exit \${REBOOT_RC:-0}
EOS
chmod 755 "$T/syscall" "$T/reboot"
printf '::sysinit:/sbin/openrc sysinit\n::shutdown:/sbin/openrc shutdown\n%s\n' "$HOOK" > "$T/inittab"
printf '::shutdown:/sbin/openrc shutdown\n' > "$T/inittab-old"
export UC_PXX_REBOOT_SYSCALL=$T/syscall UC_PXX_RUN=$T/run UC_PXX_PROC=$T/proc UC_PXX_INITTAB=$T/inittab \
	UC_PXX_INIT_REBOOT=$T/reboot UC_PXX_KMSG=/dev/null
reset() { rm -f "$T/syscall.calls" "$T/reboot.calls" "$T/run/uc-pxx-reboot.mode"; }
calls() { cat "$T/$1.calls" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
pid1() { printf "$1" > "$T/proc/1/cmdline"; }

echo "== the arguments =="
pid1 '/sbin/init\0'
for a in "" bootloader recovery normal "loader fastboot" "--dry-run bootloader" "--pending loader"; do
	reset
	# shellcheck disable=SC2086 # one word per argument
	busybox sh "$RB" $a > /dev/null 2>&1; rc=$?
	[ "$rc" = 2 ] && [ -z "$(calls syscall)$(calls reboot)" ] && ok "'$a': usage, exit 2, no restart" || bad "'$a': exit $rc, syscall '$(calls syscall)', reboot '$(calls reboot)'"
done

echo "== PID 1 is busybox init with the shutdown line =="
reset
eq "$(busybox sh "$RB" --dry-run fastboot)" "would stop the system with init, then restart with the argument 'fastboot'" "--dry-run fastboot names the init path"
eq "$(calls reboot)$(calls syscall)" "" "--dry-run restarts nothing"
reset
busybox sh "$RB" fastboot 2> "$T/err"; rc=$?
eq "$rc" 0 "fastboot: exit 0"
eq "$(calls reboot)" "fastboot" "fastboot: the mode file holds 'fastboot' when reboot runs"
eq "$(calls syscall)" "" "fastboot: no direct syscall (init stops the system first)"
grep -q 'init stops the system first' "$T/err" && ok "and it logs the path" || bad "no log line"
reset
busybox sh "$RB" loader 2>/dev/null
eq "$(calls reboot)" "loader" "loader: the mode file holds 'loader' when reboot runs"
reset
REBOOT_RC=1 busybox sh "$RB" loader 2>/dev/null; rc=$?
eq "$rc" 1 "reboot fails: exit 1"
[ ! -e "$T/run/uc-pxx-reboot.mode" ] && ok "reboot fails: the mode file is removed" || bad "the mode file stays after a failed reboot"
pid1 'init\0'
reset
eq "$(busybox sh "$RB" --dry-run loader)" "would stop the system with init, then restart with the argument 'loader'" "PID 1 'init' (no path): the init path"

echo "== --pending (the last shutdown line) =="
reset; echo fastboot > "$T/run/uc-pxx-reboot.mode"
busybox sh "$RB" --pending 2>/dev/null
eq "$(calls syscall)" "fastboot" "the mode file 'fastboot': uc-pxx-reboot-syscall fastboot"
reset; echo loader > "$T/run/uc-pxx-reboot.mode"
busybox sh "$RB" --pending 2>/dev/null
eq "$(calls syscall)" "loader" "the mode file 'loader': uc-pxx-reboot-syscall loader"
reset
busybox sh "$RB" --pending 2>/dev/null; rc=$?
eq "$rc:$(calls syscall)" "0:" "no mode file: exit 0, no syscall (a normal restart)"
reset; echo bootloader > "$T/run/uc-pxx-reboot.mode"
busybox sh "$RB" --pending 2>/dev/null; rc=$?
eq "$rc:$(calls syscall)" "0:" "a wrong mode in the file: exit 0, no syscall"

echo "== restart at once =="
pid1 '/bin/sh\0/init\0'
reset
eq "$(busybox sh "$RB" --dry-run loader)" "would restart now with the argument 'loader'" "PID 1 is the /init script: --dry-run names the direct path"
busybox sh "$RB" loader 2>/dev/null
eq "$(calls syscall):$(calls reboot)" "loader:" "PID 1 is the /init script: uc-pxx-reboot-syscall loader, no reboot"
[ ! -e "$T/run/uc-pxx-reboot.mode" ] && ok "and no mode file" || bad "a mode file on the direct path"
pid1 '/sbin/init\0'
reset
UC_PXX_INITTAB=$T/inittab-old busybox sh "$RB" fastboot 2>/dev/null
eq "$(calls syscall):$(calls reboot)" "fastboot:" "inittab without the shutdown line: uc-pxx-reboot-syscall at once"
reset
UC_PXX_PROC=$T/nothing busybox sh "$RB" fastboot 2>/dev/null
eq "$(calls syscall):$(calls reboot)" "fastboot:" "no /proc/1/cmdline: uc-pxx-reboot-syscall at once"

echo "== inittab, build and program =="
for f in "$HERE/overlay/etc/inittab" "$HERE/profiles/console/overlay/etc/inittab"; do
	n=$(grep -nxF "$HOOK" "$f" | cut -d: -f1)
	o=$(grep -nxF '::shutdown:/sbin/openrc shutdown' "$f" | cut -d: -f1)
	[ -n "$n" ] && [ -n "$o" ] && [ "$n" -gt "$o" ] && ok "${f#"$REPO"/}: the shutdown line comes after openrc shutdown" || bad "${f#"$REPO"/}: no shutdown line after openrc shutdown"
done
f=$HERE/initramfs/overlay/etc/inittab
n=$(grep -nxF "$HOOK" "$f" | cut -d: -f1)
o=$(grep -nxF '::shutdown:/bin/umount -a -r' "$f" | cut -d: -f1)
[ -n "$n" ] && [ -n "$o" ] && [ "$n" -gt "$o" ] && ok "the rescue inittab: the shutdown line comes after umount -a -r" || bad "the rescue inittab: no shutdown line after umount"
MK=$HERE/initramfs/mkinitramfs.sh
grep -q 'install -D -m 755 "$UC_PXX_REBOOT" $R/usr/libexec/uc-pxx-reboot-syscall' "$MK" &&
	grep -q 'install -D -m 755 /w/rootfs/overlay/usr/sbin/uc-pxx-reboot $R/usr/sbin/uc-pxx-reboot' "$MK" &&
	ok "the initramfs gets the script and uc-pxx-reboot-syscall" || bad "mkinitramfs.sh does not install both"
grep -q '"$UC_PXX_REBOOT" $R/usr/libexec/uc-pxx-reboot-syscall' "$HERE/mkrootfs.sh" && ok "the DEV rootfs gets uc-pxx-reboot-syscall" || bad "mkrootfs.sh does not install uc-pxx-reboot-syscall"
grep -q '/usr/libexec/uc-pxx-reboot-syscall' "$RB" && ok "the script runs /usr/libexec/uc-pxx-reboot-syscall" || bad "wrong syscall path in the script"
C=$REPO/tools/uc-pxx-reboot/uc-pxx-reboot-syscall.c
grep -q 'LINUX_REBOOT_CMD_RESTART2' "$C" && ok "uc-pxx-reboot-syscall uses RESTART2" || bad "no RESTART2"
eq "$(grep -o 'strcmp(arg, "[a-z]*")' "$C" | tr '\n' ' ')" 'strcmp(arg, "loader") strcmp(arg, "fastboot") ' "uc-pxx-reboot-syscall allows loader and fastboot only"
DT=$REPO/../linux-uc-pxx-6.18/arch/arm64/boot/dts/rockchip/rk3399-crestron-uc-pxx.dtsi
[ -f "${UC_PXX_DTSI:-$DT}" ] && DT=${UC_PXX_DTSI:-$DT}
if [ -f "$DT" ]; then
	grep -q 'mode-fastboot = <BOOT_FASTBOOT>' "$DT" && grep -q 'mode-normal = <BOOT_NORMAL>' "$DT" &&
		ok "the dtsi has mode-fastboot and mode-normal" || bad "the dtsi lacks mode-fastboot or mode-normal ($DT)"
else echo "  (no kernel checkout next to the repository: the dtsi check is skipped)"; fi

echo "$N passed, $F failed"
[ "$F" = 0 ]
