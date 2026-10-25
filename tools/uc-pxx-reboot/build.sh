#!/bin/bash
# Build the static aarch64 uc-pxx-reboot-syscall and run its test under qemu.
# Run it on a build host that has aarch64-linux-gnu-gcc and qemu-aarch64-static
# (never on a workstation). The user command uc-pxx-reboot is a shell script
# (rootfs/overlay/usr/sbin/uc-pxx-reboot). It runs this program as its last
# step.
#
#   tools/uc-pxx-reboot/build.sh [OUT]
#
# Env: CC (default aarch64-linux-gnu-gcc), QEMU (default qemu-aarch64-static),
# NO_TEST=1 (build only). OUT defaults to ./uc-pxx-reboot-syscall-aarch64.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-aarch64-linux-gnu-gcc}
QEMU=${QEMU:-qemu-aarch64-static}
OUT=${1:-${OUT:-uc-pxx-reboot-syscall-aarch64}}
$CC -O2 -Wall -Wextra -Werror -static -o "$OUT" "$HERE/uc-pxx-reboot-syscall.c"
ls -la "$OUT"; sha256sum "$OUT"
[ -n "${NO_TEST:-}" ] && exit 0
# Only --dry-run runs under qemu: the real call would restart the build host.
[ "$("$QEMU" "$OUT" --dry-run loader)" = "would reboot with the argument 'loader'" ] || { echo "FAIL: --dry-run loader"; exit 1; }
[ "$("$QEMU" "$OUT" --dry-run fastboot)" = "would reboot with the argument 'fastboot'" ] || { echo "FAIL: --dry-run fastboot"; exit 1; }
for a in bootloader recovery normal ""; do
	"$QEMU" "$OUT" --dry-run "$a" >/dev/null 2>&1 && { echo "FAIL: the argument '$a' was accepted"; exit 1; }
done
"$QEMU" "$OUT" 2>/dev/null && { echo "FAIL: no argument was accepted"; exit 1; }
echo "uc-pxx-reboot-syscall: tests ok"
