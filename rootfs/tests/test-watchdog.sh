#!/bin/sh
# Host test: the timeout and interval checks of the uc-pxx-watchdog service.
# It runs wd_prepare() from the init script with stub OpenRC functions and
# /dev/null as the watchdog device. TSX_WATCHDOG_SYSFS points to a fake
# /sys/class/watchdog.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); O=$HERE/../overlay
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

# run <expected command_args or "fail"> [VAR=value ...]
run() {
	want=$1; shift
	got=$(env -i PATH="$PATH" TSX_WATCHDOG_SYSFS="$T/sys" WATCHDOG_DEV=/dev/null "$@" sh -c '
		einfo() { echo "info: $*" >&2; }
		ewarn() { echo "warn: $*" >&2; }
		eerror() { echo "error: $*" >&2; }
		. "$1"
		[ -z "${CONF:-}" ] || { . "$CONF"; WATCHDOG_DEV=/dev/null; }
		if wd_prepare; then echo "$command_args"; else echo fail; fi' sh "$O/etc/init.d/uc-pxx-watchdog" 2> "$T/err")
	if [ "$got" = "$want" ]; then
		echo "ok: $* -> $got"
	else
		echo "FAIL: $* -> $got (want $want)"; sed 's/^/  /' "$T/err"; fail=1
	fi
}

mkdir -p "$T/sys"
run "watchdog -F -t 5 -T 20 /dev/null" CONF="$O/etc/conf.d/uc-pxx-watchdog"
run "watchdog -F -t 10 -T 30 /dev/null" WATCHDOG_TIMEOUT=30 WATCHDOG_INTERVAL=10
run "watchdog -F -t 10 -T 31 /dev/null" WATCHDOG_TIMEOUT=60 WATCHDOG_INTERVAL=10
grep -q 'above the maximum, using 31' "$T/err" || { echo "FAIL: no warning for 60"; fail=1; }
run "fail" WATCHDOG_TIMEOUT=60 WATCHDOG_INTERVAL=20
run "watchdog -F -t 5 -T 10 /dev/null" WATCHDOG_TIMEOUT=10 WATCHDOG_INTERVAL=5
run "fail" WATCHDOG_TIMEOUT=10 WATCHDOG_INTERVAL=6
run "fail" WATCHDOG_TIMEOUT=3x WATCHDOG_INTERVAL=1
run "fail" WATCHDOG_ENABLE=no WATCHDOG_TIMEOUT=20 WATCHDOG_INTERVAL=5
# a kernel with sysfs gives its own maximum
mkdir -p "$T/sys/null"; echo 20 > "$T/sys/null/max_timeout"
run "watchdog -F -t 10 -T 20 /dev/null" WATCHDOG_TIMEOUT=30 WATCHDOG_INTERVAL=10
run "watchdog -F -t 5 -T 20 /dev/null" CONF="$O/etc/conf.d/uc-pxx-watchdog"

[ $fail -eq 0 ] && echo "test-watchdog OK" || echo "test-watchdog FAILED"
exit $fail
