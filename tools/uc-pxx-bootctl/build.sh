#!/bin/bash
# Build the static aarch64 uc-pxx-bootctl and run its tests under qemu.
# Run it on a build host that has aarch64-linux-gnu-gcc and qemu-aarch64-static
# (never on a workstation).
#
#   tools/uc-pxx-bootctl/build.sh [OUT]
#
# Env: CC (default aarch64-linux-gnu-gcc), QEMU (default qemu-aarch64-static),
# SECTORS (folders with captured *.bin sectors for the tests, optional),
# NO_TEST=1 (build only). OUT defaults to ./uc-pxx-bootctl-aarch64.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-aarch64-linux-gnu-gcc}
QEMU=${QEMU:-qemu-aarch64-static}
OUT=${1:-${OUT:-uc-pxx-bootctl-aarch64}}
$CC -O2 -Wall -Wextra -Werror -static -o "$OUT" "$HERE/uc-pxx-bootctl.c"
ls -la "$OUT"; sha256sum "$OUT"
[ -n "${NO_TEST:-}" ] && exit 0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf '#!/bin/sh\nexec %s %s "$@"\n' "$QEMU" "$(realpath "$OUT")" > "$W/run.sh"
chmod 755 "$W/run.sh"
# shellcheck disable=SC2086 # SECTORS is a list of folders
python3 "$HERE/test.py" "$W/run.sh" ${SECTORS:-}
