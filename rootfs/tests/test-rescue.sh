#!/bin/sh
# Host test for the rescue system of the initramfs. It needs no panel and no
# compiler. The tools of tsx-linux-common come from TSX_COMMON (a checkout; the
# default is ../tsx-linux-common next to the repository). Without it the test
# prints SKIPPED. Run it with busybox sh: the screen script uses read -t.
#   - the files of the overlay: syntax, modes, no baked key or password
#   - mkinitramfs.sh: the tools it installs, the dev variables, no baked key
#     without TSX_DEV_RESCUE_KEYS
#   - the rescue screen (tsx-rescue-status once) with the board file of this
#     repository: model from the device tree, MAC from the cfg partition, the
#     login, the reason, the A/B state
#   - the console font for the turned 1200x1920 panel (tsx-confont)
#   - the login (tsx-rescue-login) with a made-up root file system: the key of
#     the panel, and the one-time password
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/.." && pwd)
COMMON=${TSX_COMMON:-$REPO/../tsx-linux-common}
OVL=$HERE/initramfs/overlay
BOARD=$HERE/overlay/usr/local/lib/tsx/board.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== the files of the overlay =="
for f in init etc/init.d/rcS usr/sbin/uc-pxx-install-rootfs usr/sbin/uc-pxx-rescue-help etc/profile.d/uc-pxx-rescue.sh; do
	busybox sh -n "$OVL/$f" 2>/dev/null && ok "$f passes busybox sh -n" || bad "$f: busybox sh -n"
done
for f in etc/init.d/rcS usr/sbin/uc-pxx-install-rootfs usr/sbin/uc-pxx-rescue-help; do
	[ -x "$OVL/$f" ] && ok "$f is executable" || bad "$f is not executable"
done
grep -q '^tty1::respawn:/usr/sbin/tsx-rescue-status loop$' "$OVL/etc/inittab" && ok "inittab: the rescue screen runs on tty1" || bad "inittab: no tsx-rescue-status on tty1"
grep -q 'ttyS2' "$OVL/etc/inittab" && ok "inittab: the shell on ttyS2" || bad "inittab: no shell on ttyS2"
if grep -rq 'authorized_keys\|ssh-ed25519\|ssh-rsa' "$OVL" 2>/dev/null; then
	bad "the overlay has an authorized_keys file or a key"
else ok "the overlay has no baked key"; fi
# the tools that xx70 has and the UC-P10 must not have
for f in tsx-restore-slot-a tsx-factory-restore tsx-boot-mainline tsx-usb-recover; do
	[ -e "$OVL/usr/sbin/$f" ] && bad "$f is in the overlay" || ok "no $f in the overlay"
done
grep -q 'tsx-rescue-login' "$OVL/etc/init.d/rcS" && ok "rcS runs tsx-rescue-login" || bad "rcS does not run tsx-rescue-login"
grep -q 'authorized_keys' "$OVL/etc/init.d/rcS" && bad "rcS looks at an authorized_keys file itself" || ok "rcS does not look at an authorized_keys file"
grep -q 'rescue-reason' "$OVL/init" && ok "init writes /run/rescue-reason for the screen" || bad "init does not write /run/rescue-reason"

echo "== mkinitramfs.sh =="
MK=$HERE/initramfs/mkinitramfs.sh
busybox sh -n "$MK" 2>/dev/null && ok "mkinitramfs.sh passes busybox sh -n" || bad "mkinitramfs.sh: busybox sh -n"
for f in tsx-rescue-status tsx-confont tsx-rescue-backlight tsx-rescue-login tsx-data-backup tsx-data-restore; do
	grep -q "$f" "$MK" && ok "mkinitramfs.sh installs $f" || bad "mkinitramfs.sh does not install $f"
done
for f in tsx-restore-slot-a tsx-factory-restore tsx-boot-mainline tsx-usb-recover; do
	grep -q "$f" "$MK" && bad "mkinitramfs.sh mentions $f" || ok "mkinitramfs.sh has no $f"
done
grep -q '^BOOTCTL_SHA256=38fea6d32412e7977ebc5845b138dc1c8c2df8555dae0b64b47f8a851b45e2d7$' "$MK" && ok "the reviewed uc-pxx-bootctl sha256" || bad "wrong or missing BOOTCTL_SHA256"
if grep -n 'AUTHORIZED_KEYS' "$MK" | grep -v '^[0-9]*:#' | grep -q .; then bad "mkinitramfs.sh uses AUTHORIZED_KEYS in code"; else ok "mkinitramfs.sh does not use AUTHORIZED_KEYS"; fi
grep -q 'TSX_DEV_RESCUE_KEYS' "$MK" && grep -q 'TSX_DEV_RESCUE_HASH' "$MK" && ok "the dev variables TSX_DEV_RESCUE_KEYS and TSX_DEV_RESCUE_HASH" || bad "dev variables missing"
kl=$(grep -n 'if \[ -n "\${TSX_DEV_RESCUE_KEYS' "$MK" | head -n 1 | cut -d: -f1)
al=$(grep -n 'authorized_keys' "$MK" | grep -v '^[0-9]*:#' | head -n 1 | cut -d: -f1)
[ -n "$kl" ] && [ -n "$al" ] && [ "$al" -gt "$kl" ] && ok "a key is baked only inside the TSX_DEV_RESCUE_KEYS test" || bad "a key is baked outside TSX_DEV_RESCUE_KEYS"
cat "$MK" "$HERE/mkrootfs.sh" "$HERE/build-rootfs.sh" | grep -v '^[[:space:]]*#' | grep -q '1920x1200\|1200x1920' && bad "a build file still names the 1920x1200 splash" || ok "no build file renders a 1920x1200 splash"
grep -q 'UC_PXX_SPLASH_SIZES' "$MK" && grep -q 'UC_PXX_SPLASH_SIZES' "$HERE/mkrootfs.sh" && ok "the hook UC_PXX_SPLASH_SIZES is in the initramfs and rootfs builds" || bad "UC_PXX_SPLASH_SIZES missing"

if [ ! -f "$COMMON/rescue/usr/sbin/tsx-rescue-status" ]; then
	echo "SKIPPED: no tsx-linux-common checkout (TSX_COMMON) for the screen tests"
	echo "$N passed, $F failed"; [ "$F" = 0 ]; exit
fi
RS=$COMMON/rescue/usr/sbin/tsx-rescue-status

echo "== the rescue screen with the board file of the UC-P10 =="
mkdir -p "$T/run" "$T/sbin"
printf '#!/bin/sh\necho "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"\n' > "$T/sbin/ip"
printf '#!/bin/sh\necho 6.18.54-test\n' > "$T/sbin/uname"
printf '#!/bin/sh\necho uc-pxx-rescue\n' > "$T/sbin/hostname"
chmod 755 "$T/sbin/ip" "$T/sbin/uname" "$T/sbin/hostname"
# a made-up cfg partition with the MAC at byte 6
dd if=/dev/zero of="$T/cfg" bs=1k count=64 status=none
printf '\000\020\177\001\002\003' | dd of="$T/cfg" bs=1 seek=6 conv=notrunc status=none
# a made-up device tree and a made-up uc-pxx-bootctl
printf 'crestron,uc-p10\0rockchip,rk3399\0' > "$T/compatible"
cat > "$T/bootctl" <<'BC'
#!/bin/sh
echo "uc-pxx-bootctl: current: A{prio 15 tries 7 succ 0} B{prio 14 tries 0 succ 1} crc da933679" >&2
echo "libavb-would-boot: a"
BC
chmod 755 "$T/bootctl"
echo "uc-pxx initramfs rescue (boot image)" > "$T/rver"
echo "quiet console=tty0" > "$T/cmdline"
echo "/etc/uc-pxx-force-rescue was on the root file system, so the rescue starts and this reason is long enough to wrap" > "$T/run/rescue-reason"
sed -e "s|/proc/cmdline|$T/cmdline|g" -e "s|ip -4 -o addr show eth0|$T/sbin/ip|g" -e "s|uname -r|$T/sbin/uname|" \
    -e 's|> /dev/kmsg|> /dev/null|; s|> "\$TTY"|>> "$TTY"|' "$RS" > "$T/rs.sh"
sed -e "s|hostname 2>|$T/sbin/hostname 2>|" "$BOARD" > "$T/board.sh"
export TSX_BOARD_CONF=$T/board.sh TSX_RUN=$T/run TSX_STATUS_TTY=$T/frame.raw TSX_VERFILE=$T/rver TSX_STATUS_IN=$T/keys TSX_STATUS_WAIT=1
export TSX_CFG=$T/cfg TSX_DT_COMPATIBLE=$T/compatible TSX_BOOTCTL=$T/bootctl
render() {
	: > "$T/frame.raw"
	sh "$T/rs.sh" once 2>/dev/null
	sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"
}
want()    { if grep -q -- "$1" "$T/frame"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
wantnot() { if grep -q -- "$1" "$T/frame"; then bad "$2 (found: $1)"; else ok "$2"; fi; }
render
want '^model        : UC-P10' "the model comes from the device tree"
want '^network      : eth0 192.0.2.10 (dhcp' "the IP address"
want '^hostname     : uc-pxx-rescue$' "the host name"
want '^reason       : /etc/uc-pxx-force-rescue was on the root file system' "the reason"
want '^               [a-z]' "a long reason wraps under its label"
want '^slot A       : priority 15, tries 7, successful 0$' "the A/B state of slot A"
want '^slot B       : priority 14, tries 0, successful 1$' "the A/B state of slot B"
want '^next boot    : slot A$' "the slot that libavb boots"
want '^login        : starting$' "the login line before tsx-rescue-login has run"
want 'rescue$' "the banner says rescue"
# before rcS has set the MAC: "(starting)" and the MAC of the cfg partition
rm -f "$T/run/tsx-eth0-mac-src"
render
want 'MAC 00:10:7f:01:02:03' "the MAC comes from the cfg partition (bytes 6 to 11)"
echo cfg > "$T/run/tsx-eth0-mac-src"; render
want ', cfg)' "the MAC source is cfg"
echo onetime > "$T/run/tsx-rescue-login"; echo abcd23efgh > "$T/run/tsx-rescue-otp"; render
want '^login        : root, one-time password abcd23efgh$' "the one-time password is on the screen"
echo panel > "$T/run/tsx-rescue-login"; render
want '^login        : the root password or SSH key of this panel$' "the panel login"
wantnot 'abcd23efgh' "the one-time password is gone when the login is the panel's"
# a bootctl that fails
printf '#!/bin/sh\necho "uc-pxx-bootctl: refusing: x" >&2\nexit 1\n' > "$T/bootctl"; rm -f "$T/run/uc-pxx-ab-state"; render
want '^A/B state    : cannot read (uc-pxx-bootctl status, exit 1)$' "an unreadable A/B state is shown, not hidden"
# no line is longer than 80 columns
cols=$(awk '{ if (length > m) m = length } END { print m + 0 }' "$T/frame")
[ "$cols" -le 80 ] && ok "widest line $cols <= 80 columns" || bad "widest line $cols > 80"
# the A/B state is kept for 60 s: the second draw does not call uc-pxx-bootctl
printf '#!/bin/sh\necho x >> "%s/calls"\necho "uc-pxx-bootctl: current: A{prio 15 tries 7 succ 0} B{prio 14 tries 0 succ 1} crc 0" >&2\n' "$T" > "$T/bootctl"
rm -f "$T/run/uc-pxx-ab-state" "$T/calls"; render; render; render
eq "$(wc -l < "$T/calls" | tr -d ' ')" 1 "three draws read the A/B state once"
# the clock of the rescue starts at 0 (no RTC): with no cache file the first draw reads the state
mkdir -p "$T/epoch"
printf '#!/bin/sh\n[ "$1" = +%%s ] && { echo 30; exit 0; }\nexec /bin/date "$@"\n' > "$T/epoch/date"; chmod 755 "$T/epoch/date"
printf '#!/bin/sh\necho x >> "%s/calls"\necho "uc-pxx-bootctl: current: A{prio 15 tries 7 succ 0} B{prio 14 tries 0 succ 1} crc 0"\n' "$T" > "$T/bootctl"
rm -f "$T/run/uc-pxx-ab-state" "$T/calls"; PATH=$T/epoch:$PATH render
eq "$(wc -l < "$T/calls" 2>/dev/null | tr -d ' ')" 1 "clock at 30 s and no cache file: the first draw reads the A/B state"
want '^slot A       : priority 15, tries 7, successful 0$' "and shows the slots, not \"cannot read\""

echo "== the console font for the turned 1200x1920 panel =="
CF=$COMMON/rescue/usr/sbin/tsx-confont
mkdir -p "$T/sys/class/graphics/fb0" "$T/sys/class/graphics/fbcon" "$T/fonts"
for n in ter-116b ter-118b ter-120b ter-122b ter-124b ter-128b ter-132b; do echo font > "$T/fonts/$n.psf"; done
echo "U:1200x1920p-0" > "$T/sys/class/graphics/fb0/modes"
echo 3 > "$T/sys/class/graphics/fbcon/rotate"
eq "$(TSX_SYSFS=$T/sys TSX_CONFONT_DIR=$T/fonts sh "$CF" -n)" "ter-132b 120x37" "rotate 3: the console is 1920x1200, font 16x32, 120x37 cells"
echo 0 > "$T/sys/class/graphics/fbcon/rotate"
eq "$(TSX_SYSFS=$T/sys TSX_CONFONT_DIR=$T/fonts sh "$CF" -n)" "ter-128b 85x68" "rotate 0: the console is 1200x1920, font 14x28"
grep -q 'rotate_all' "$OVL/init" && ok "init sets the rotation of the console (rotate_all) before the font" || bad "init does not set rotate_all"

echo "== the login of the rescue (tsx-rescue-login) =="
RL=$COMMON/rescue/usr/sbin/tsx-rescue-login
mkroot() { # DIR: a made-up root file system
	rm -rf "$1"; mkdir -p "$1/data/tsx" "$1/root/.ssh"
}
cat > "$T/findfs" <<'FF'
#!/bin/sh
case $1 in LABEL=tsxroot) echo /dev/fake;; *) exit 1;; esac
FF
cat > "$T/mount" <<EOM
#!/bin/sh
# mount -t ext4 -o ro,noload DEV MNT: copy the made-up root file system
for a; do m=\$a; done
cp -a "$T/rootfs/." "\$m/"
EOM
cat > "$T/umount" <<'EOM'
#!/bin/sh
exit 0
EOM
chmod 755 "$T/findfs" "$T/mount" "$T/umount"
runlogin() { # run the login script with the hooks; $1 = case file target
	rm -rf "$T/lrun" "$T/lroot"; mkdir -p "$T/lrun" "$T/lroot"
	printf 'root:*:19000:0:99999:7:::\nbin:*:19000:0:99999:7:::\n' > "$T/shadow"
	TSX_RESCUE_SHADOW=$T/shadow TSX_RESCUE_ROOT=$T/lroot TSX_RESCUE_RUN=$T/lrun TSX_RESCUE_WAIT=0 \
	TSX_RESCUE_FINDFS=$T/findfs TSX_RESCUE_MOUNT=$T/mount TSX_RESCUE_UMOUNT=$T/umount \
	TSX_RESCUE_CHPASSWD="cat" TSX_RESCUE_URANDOM=/dev/urandom sh "$RL" > "$T/login.out" 2>&1
}
mkroot "$T/rootfs"
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPanelKeyForTheTest panel@test' > "$T/rootfs/root/.ssh/authorized_keys"
printf 'KIOSK_URL=https://ha.example.org\n' > "$T/rootfs/data/tsx/panel.conf"
runlogin
eq "$(cat "$T/lrun/tsx-rescue-login")" panel "a root file system with a key: the panel login"
grep -q 'PanelKeyForTheTest' "$T/lroot/.ssh/authorized_keys" && ok "the key of root becomes the key of the rescue" || bad "the key of root is not in the rescue"
[ ! -e "$T/lrun/tsx-rescue-otp" ] && ok "no one-time password when the panel has a key" || bad "a one-time password exists"
HASH='$6$saltsalt$0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./abcdefghijklmnopq'
printf 'ROOT_PASSWORD_HASH=%s\n' "$HASH" >> "$T/rootfs/data/tsx/panel.conf"
runlogin
grep -q "^root:\\$HASH:" "$T/shadow" && ok "ROOT_PASSWORD_HASH of panel.conf becomes the password of root" || bad "the hash is not in shadow"
mkroot "$T/rootfs"; : > "$T/rootfs/root/.ssh/authorized_keys"
runlogin
eq "$(cat "$T/lrun/tsx-rescue-login")" onetime "no key and no hash: a one-time password"
[ -s "$T/lrun/tsx-rescue-otp" ] && ok "the password is in /run only" || bad "no password file"
grep -rq "$(cat "$T/lrun/tsx-rescue-otp")" "$T/login.out" && bad "the script printed the password" || ok "the script does not print the password"

echo "$N passed, $F failed"
[ "$F" = 0 ]
