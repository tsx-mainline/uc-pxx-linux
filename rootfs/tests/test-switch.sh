#!/bin/sh
# Host test for uc-pxx-switch with a stub ip command, a stub rtl8363-init and
# a made-up cfg partition and network folder.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
P=$HERE/overlay/usr/local/sbin/uc-pxx-switch
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

busybox sh -n "$P" && ok "uc-pxx-switch passes busybox sh -n" || bad "busybox sh -n"
mkdir -p "$T/net/eth0" "$T/bin" "$T/smi"
echo 0x1002 > "$T/net/eth0/flags"
touch "$T/smi/smi"
dd if=/dev/zero of="$T/cfg" bs=1k count=64 status=none
printf '\000\020\177\001\002\003' | dd of="$T/cfg" bs=1 seek=6 conv=notrunc status=none
printf '#!/bin/sh\necho "ip $*" >> "$LOG"\n' > "$T/bin/ip"
printf '#!/bin/sh\necho "tool $*" >> "$LOG"\n' > "$T/bin/rtl8363-init"
chmod 755 "$T/bin/ip" "$T/bin/rtl8363-init"
sw() { env -i PATH="$T/bin:$PATH" LOG="$T/log" UC_PXX_SYSNET="$T/net" UC_PXX_SMI_GLOB="$T/smi/smi" UC_PXX_SMI_WAIT=0 \
	TSX_BOARD_CONF="$HERE/overlay/usr/local/lib/tsx/board.sh" RTL8363_INIT="$T/bin/rtl8363-init" "$@" sh "$P" start; }

: > "$T/log"; sw TSX_CFG="$T/cfg" >/dev/null 2>&1
grep -q 'ip link set dev eth0 address 00:10:7f:01:02:03' "$T/log" && ok "the MAC address comes from the cfg partition" || bad "no MAC: $(cat "$T/log")"
grep -q '^tool init' "$T/log" && ok "the switch init runs" || bad "no switch init"
grep -q 'link set dev eth0 up' "$T/log" && bad "the script brought eth0 up" || ok "the script leaves eth0 down"

: > "$T/log"; sw TSX_CFG="$T/none" >/dev/null 2>&1
grep -q 'address' "$T/log" && bad "set a MAC without a valid source" || ok "no valid MAC: eth0 keeps its address"
grep -q '^tool init' "$T/log" && ok "the switch init still runs" || bad "no switch init without a MAC"

echo 0x1003 > "$T/net/eth0/flags"; : > "$T/log"
sw TSX_CFG="$T/cfg" 2>&1 | grep -q 'up already' && ok "eth0 up: the script stops" || bad "no message for an up interface"
[ ! -s "$T/log" ] && ok "eth0 up: nothing runs" || bad "ran with eth0 up: $(cat "$T/log")"
echo "$N passed, $F failed"
[ "$F" = 0 ]
