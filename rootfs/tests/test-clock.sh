#!/bin/sh
# Host test for uc-pxx-clock with a made-up floor file and stubs for date and
# hwclock. It checks that the clock moves only forward to the floor and that
# the RTC is written then. It also checks the write-back sysctl file.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
P=$HERE/overlay/usr/local/sbin/uc-pxx-clock
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

busybox sh -n "$P" && ok "uc-pxx-clock passes busybox sh -n" || bad "busybox sh -n"
busybox sh -n "$HERE/overlay/etc/init.d/uc-pxx-clock" && ok "the init script passes busybox sh -n" || bad "init: busybox sh -n"
printf '#!/bin/sh\necho "date $*" >> "%s/calls"\n' "$T" > "$T/date"
printf '#!/bin/sh\necho "hwclock $*" >> "%s/calls"\n' "$T" > "$T/hwclock"
chmod 755 "$T/date" "$T/hwclock"
: > "$T/floor"; touch -d @1790000000 "$T/floor"
clk() { : > "$T/calls"; env -i PATH="$PATH" UC_PXX_CLOCK_FLOOR="$T/floor" UC_PXX_CLOCK_NOW="$1" \
	UC_PXX_DATE="$T/date" UC_PXX_HWCLOCK="$T/hwclock" sh "$P" boot 2>&1; }

out=$(clk 1370000000)
eq "$(cat "$T/calls" | tr '\n' ';')" "date -u -s @1790000000;hwclock -w -u;" "2013 (a power cut): set the clock to the floor, then write the RTC"
echo "$out" | grep -q 'before the floor' && ok "it logs the reason" || bad "no reason in: $out"
out=$(clk 1790000500)
eq "$(cat "$T/calls")" "" "a clock after the floor: no change"
echo "$out" | grep -q 'no change' && ok "it logs no change" || bad "no log: $out"
clk 1790000000 >/dev/null; eq "$(cat "$T/calls")" "" "a clock at the floor: no change"
rm -f "$T/floor"; out=$(clk 1370000000)
eq "$(cat "$T/calls")" "" "no floor file: no change"
env -i PATH="$PATH" sh "$P" bogus >/dev/null 2>&1; eq "$?" 2 "an unknown command exits 2"

S=$HERE/overlay/etc/sysctl.d/uc-pxx-writeback.conf
eq "$(grep -v '^#' "$S" | grep . | tr -d ' ' | tr '\n' ';')" "vm.dirty_expire_centisecs=500;vm.dirty_writeback_centisecs=100;" "the write-back sysctl values"
echo "$N passed, $F failed"
[ "$F" = 0 ]
