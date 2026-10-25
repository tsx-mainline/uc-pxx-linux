#!/bin/bash
# Build the static aarch64 uc-pxx-reboot and run its test under qemu. Run it on
# a build host that has aarch64-linux-gnu-gcc and qemu-aarch64-static (never on
# a workstation).
#
#   tools/uc-pxx-reboot/build.sh [OUT]
#
# Env: CC (default aarch64-linux-gnu-gcc), QEMU (default qemu-aarch64-static),
# NO_TEST=1 (build only). OUT defaults to ./uc-pxx-reboot-aarch64.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-aarch64-linux-gnu-gcc}
QEMU=${QEMU:-qemu-aarch64-static}
OUT=${1:-${OUT:-uc-pxx-reboot-aarch64}}
$CC -O2 -Wall -Wextra -Werror -static -o "$OUT" "$HERE/uc-pxx-reboot.c"
ls -la "$OUT"; sha256sum "$OUT"
[ -n "${NO_TEST:-}" ] && exit 0
# Only --dry-run runs under qemu: the real call would restart the build host.
[ "$("$QEMU" "$OUT" --dry-run loader)" = "would reboot with the argument 'loader'" ] || { echo "FAIL: --dry-run"; exit 1; }
"$QEMU" "$OUT" bootloader 2>/dev/null && { echo "FAIL: another argument was accepted"; exit 1; }
"$QEMU" "$OUT" 2>/dev/null && { echo "FAIL: no argument was accepted"; exit 1; }
echo "uc-pxx-reboot: tests ok"
