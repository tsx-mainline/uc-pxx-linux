#!/bin/sh
# Mark this slot's boot successful once the system has been healthy for a while, like Android's
# update_verifier + boot_control markBootSuccessful(). Until then the slot stays "trying", so a bad image
# keeps using up its tries and U-Boot falls back to the other slot.
# Started in the background by /etc/init.d/uc-pxx-boot-ok. The mainline image only ever lives in boot_a, so it expects slot A.
#
# Off switches: kernel cmdline "uc-pxx.nomark", or the file /etc/uc-pxx-nomark (dev/test images).
# Image identity: the word uc-pxx.id=TOKEN on the kernel command line (kernel/mkimage.sh puts it into the
# device tree of the boot image) must equal the name field of the boot_a header, so a `fastboot boot`
# RAM boot never blesses whatever happens to be in boot_a. The token comes ONLY from /proc/cmdline, never
# from a file of the root file system (system_a is not part of the running image).

HEALTH_SECS=60
NET_WAIT_SECS=300

log() { echo "uc-pxx-mark-boot: $*" > /dev/kmsg; }

if grep -qw uc-pxx.nomark /proc/cmdline || [ -e /etc/uc-pxx-nomark ]; then
	log "marking disabled (uc-pxx.nomark / /etc/uc-pxx-nomark), slot left as is"
	exit 0
fi
TOKEN=
# no glob expansion: a cmdline word must never match a file in the root fs
set -f
for w in $(cat /proc/cmdline); do
	case $w in uc-pxx.id=*) [ -n "$TOKEN" ] || TOKEN=${w#uc-pxx.id=};; esac
done
set +f
if [ -z "$TOKEN" ]; then
	log "no uc-pxx.id= on the kernel command line, NOT marking"
	exit 1
fi

while [ "$(cut -d. -f1 /proc/uptime)" -lt "$HEALTH_SECS" ]; do sleep 5; done

# healthy = reachable: LAN (eth0 has an IPv4 address) or USB link (usb0 configured), and sshd running
net_ok() {
	ip -f inet addr show dev eth0 2>/dev/null | grep -q "inet " && return 0
	ip -f inet addr show dev usb0 2>/dev/null | grep -q "inet " && \
		[ "$(cat /sys/class/udc/*/state 2>/dev/null | head -1)" = configured ] && return 0
	return 1
}
waited=0
until net_ok && pidof sshd >/dev/null; do
	if [ "$waited" -ge "$NET_WAIT_SECS" ]; then
		log "no network/ssh after ${NET_WAIT_SECS}s, NOT marking (slot stays trying)"
		exit 1
	fi
	sleep 10
	waited=$((waited + 10))
done

# kernel taint bit 7 (D) = an oops/BUG happened; do not bless a kernel that has died once
if [ $(( $(cat /proc/sys/kernel/tainted) & 128 )) -ne 0 ]; then
	log "kernel oops seen (taint $(cat /proc/sys/kernel/tainted)), NOT marking"
	exit 1
fi

# F1: never race the flash wrapper or uc-pxx-arm-slot. They hold this lock while they arm slot A, and they
# leave /run/uc-pxx-slot-a-changed behind: once boot_a or system_a has been changed under this running
# image, this (old) image must never mark anything.
exec 9>/run/uc-pxx-abdata.lock
if ! flock -n 9; then
	log "A/B lock busy (flash in progress), NOT marking"
	exit 1
fi
if [ -e /run/uc-pxx-slot-a-changed ]; then
	log "slot A was changed during this boot, NOT marking"
	exit 1
fi
/usr/sbin/uc-pxx-bootctl mark-successful --expect a --token "$TOKEN"
rc=$?
flock -u 9
case $rc in
	0) log "boot marked successful (or already was)" ;;
	1) log "uc-pxx-bootctl refused, slot left as is" ;;
	2) log "uc-pxx-bootctl I/O error, original A/B sector verified intact" ;;
	*) log "!!! uc-pxx-bootctl rc $rc: A/B STATE UNKNOWN - DO NOT REBOOT, inspect LBA 49156 !!!"
	   echo 1 > /sys/class/leds/red/brightness 2>/dev/null ;;
esac
exit $rc
