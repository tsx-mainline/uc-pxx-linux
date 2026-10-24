#!/bin/sh
# Host test for the layout of the package uc-pxx-leds: the file list FILES and
# the tree root/ are the same, the modes match, and the rest of the repository
# does not write the LEDs of the package (the daemon is the only writer).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/../.." && pwd)
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== the file list =="
listed=$(awk '/^[ \t]*(#|$)/ { next } { print $2 }' "$HERE/FILES" | sort)
tree=$(cd "$HERE/root" && find . -type f | sed 's|^\./||' | sort)
eq "$tree" "$listed" "FILES lists every file of root/ and nothing else"
badmode=$(awk '/^[ \t]*(#|$)/ { next } { print $1 " " $2 }' "$HERE/FILES" | while read -r mode path; do
	got=$(stat -c %a "$HERE/root/$path"); want=${mode#0}
	[ "$got" = "$want" ] || echo "mode of $path: $got, want $want"
done)
eq "$badmode" "" "the mode of each file is the mode in FILES"
dup=$(awk '/^[ \t]*(#|$)/ { next } { print $2 }' "$HERE/FILES" | sort | uniq -d)
eq "$dup" "" "no file is listed twice"
grep -q '^[ \t]*[0-9]\{4\} /' "$HERE/FILES" && bad "a path in FILES starts with /" || ok "the paths in FILES are relative"
for f in $(find "$HERE/root" -type f); do
	case "$f" in
	*/uc-pxx-leds.py) head -n 1 "$f" | grep -q '^# SPDX-License-Identifier: GPL-2.0-or-later$' && ok "$(basename "$f"): license line" || bad "$f: no license line";;
	*/sbin/uc-pxx-leds|*/bin/uc-pxx-led) sed -n 2p "$f" | grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' && ok "$(basename "$f"): license line" || bad "$f: no license line";;
	esac
done

echo "== the daemon is the only writer =="
# The scripts that the A/B boot control owns write the red LED as an alarm.
# Nothing else may write an LED class device.
hits=$(cd "$REPO" && grep -rIl '/sys/class/leds' rootfs tools kernel ci 2>/dev/null \
	| grep -v -e '^rootfs/tests/' -e 'uc-pxx-arm-slot$' -e 'uc-pxx-mark-boot.sh$' -e 'uc-pxx-flash-boot$' || true)
eq "$hits" "" "no other file of the repository names /sys/class/leds"
if (cd "$REPO" && grep -n '/sys/class/leds' rootfs/overlay/usr/sbin/uc-pxx-arm-slot rootfs/overlay/etc/uc-pxx-mark-boot.sh rootfs/overlay/usr/sbin/uc-pxx-flash-boot 2>/dev/null \
	| grep -v '/sys/class/leds/red/brightness'); then bad "a boot-control script writes an LED other than red"; else ok "the boot-control scripts write only the red LED"; fi
[ ! -e "$REPO/rootfs/overlay/usr/local/sbin/uc-pxx-status-led" ] && [ ! -e "$REPO/rootfs/overlay/etc/init.d/uc-pxx-status-led" ] \
	&& ok "uc-pxx-status-led is gone (the daemon shows the boot state)" || bad "uc-pxx-status-led is still in the overlay"
grep -rq 'uc-pxx-status-led' "$REPO/rootfs/profiles" && bad "a profile still starts uc-pxx-status-led" || ok "no profile starts uc-pxx-status-led"
grep -q '^svc default uc-pxx-leds$' "$REPO/rootfs/profiles/console.list" && ok "the console profile starts uc-pxx-leds" || bad "no uc-pxx-leds in the console profile"

echo "$N passed, $F failed"
[ "$F" = 0 ]
