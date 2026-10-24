#!/bin/bash
# Build the static aarch64 rtl8363-init tool. Run it on a build host.
#
#   SDK=DIR tools/rtl8363-init/build.sh [OUT]
#
# SDK is the folder rtl8367c of the Realtek switch SDK (GPL-2.0). This
# repository does not hold the SDK. Get it from OpenWrt:
#   commit 4e1d1b7df0ce6fa96d7462dc883917682f428046 of branch openwrt-22.03,
#   path target/linux/mediatek/files-5.10/drivers/net/phy/rtk/rtl8367c
#   git clone --depth 1 --filter=blob:none --sparse -b openwrt-22.03 https://github.com/openwrt/openwrt.git owrt
#   cd owrt && git sparse-checkout set --no-cone "target/linux/mediatek/files-5.10/drivers/net/phy/rtk/**"
# The script copies the SDK to a temporary folder, applies
# sdk-8364b-stock-sram.patch and builds with main.c and smi_mdio.c.
# Env: SDK (required), CC (default aarch64-linux-gnu-gcc), OUT (default
# ./rtl8363-init).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SDK=${SDK:?set SDK to the folder rtl8367c of the Realtek SDK (see the header of this script)}
CC=${CC:-aarch64-linux-gnu-gcc}
OUT=${1:-${OUT:-rtl8363-init}}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp -a "$SDK" "$W/sdk"
patch -d "$W/sdk" -p1 < "$HERE/sdk-8364b-stock-sram.patch"
SRCS=$(ls "$W"/sdk/*.c | grep -v -e '/smi.c$' -e '/rtk_hal.c$')
# shellcheck disable=SC2086 # one word per source file
$CC -static -Os -s -std=gnu99 -D_LITTLE_ENDIAN -DMDC_MDIO_OPERATION -I"$W/sdk/include" -I"$HERE" -w \
    -ffunction-sections -fdata-sections -Wl,--gc-sections \
    -o "$OUT" "$HERE/main.c" "$HERE/smi_mdio.c" $SRCS
file "$OUT"; ls -la "$OUT"; sha256sum "$OUT"
