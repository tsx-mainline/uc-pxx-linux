#!/bin/sh
# Host test for uc-pxx-audio with a stub amixer. It checks the mixer defaults,
# the volume steps and the saved state.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
A=$HERE/overlay/usr/local/sbin/uc-pxx-audio
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

busybox sh -n "$A" && ok "uc-pxx-audio passes busybox sh -n" || bad "busybox sh -n"
mkdir -p "$T/asound/UCP10" "$T/state"
cat > "$T/amixer" <<'STUB'
#!/bin/sh
echo "$*" >> "$AMIXER_LOG"
STUB
chmod 755 "$T/amixer"
cat > "$T/audio.conf" <<'CONF'
SPEAKER_VOLUME=75
VOLUME_MAX=100
VOLUME_MIN=40
VOLUME_SENDSPIN=100
MIC_VOLUME=30
CONF
ua() { env -i PATH="$PATH" AMIXER="$T/amixer" AMIXER_LOG="$T/log" TSX_BOARD_CONF="$HERE/overlay/usr/local/lib/tsx/board.sh" TSX_AUDIO_CONF="$T/audio.conf" TSX_ASOUND_DIR="$T/asound" \
	UC_PXX_STATE_DIR="$T/state" UC_PXX_CARD_WAIT=0 sh "$A" "$@"; }

echo "== init =="
: > "$T/log"; ua init >/dev/null 2>&1
eq "$(grep -c 'name=Left DAC Mux' "$T/log")" 1 "init sets the left DAC mux"
grep -q 'name=Right Line Mixer DACR1 Switch on' "$T/log" && ok "the right DAC goes to the right line out" || bad "no right line mixer"
grep -q 'name=PCM Playback Volume 75,75' "$T/log" && ok "the first boot uses SPEAKER_VOLUME" || bad "no default speaker volume"
grep -q 'name=ADC HPF Cut-off 0.0045xFs,0.0045xFs' "$T/log" && ok "the ADC high-pass filter is on" || bad "no ADC filter"
grep -q -e '-c UCP10' "$T/log" && ok "the card is UCP10" || bad "wrong card"

echo "== no card =="
rm -rf "$T/asound/UCP10"; : > "$T/log"
ua init >/dev/null 2>&1; eq "$?" 0 "init without a card exits 0"
eq "$(wc -c < "$T/log" | tr -d ' ')" 0 "init without a card sets nothing"
ua volume >/dev/null 2>&1; eq "$?" 2 "volume without a card exits 2"
mkdir -p "$T/asound/UCP10"

echo "== volume =="
eq "$(ua volume 50)" 50 "volume 50 prints 50"
eq "$(ua volume)" 50 "the saved volume"
eq "$(cat "$T/state/volume")" 50 "the state file"
: > "$T/log"; ua volume 100 >/dev/null
grep -q 'PCM Playback Volume 100,100' "$T/log" && ok "100 % is VOLUME_MAX" || bad "100 %: $(cat "$T/log")"
: > "$T/log"; ua volume 1 >/dev/null
grep -q 'PCM Playback Volume 40,40' "$T/log" && ok "1 % is VOLUME_MIN" || bad "1 %: $(cat "$T/log")"
: > "$T/log"; ua volume 0 >/dev/null
grep -q 'PCM Playback Volume 0,0' "$T/log" && ok "0 % is the control value 0" || bad "0 %: $(cat "$T/log")"
eq "$(ua volume 90; ua volume +20)" "90
100" "+20 stops at 100"
eq "$(ua volume 5; ua volume -20)" "5
0" "-20 stops at 0"
ua volume 3x >/dev/null 2>&1; eq "$?" 2 "a bad number is refused"
ua volume +x >/dev/null 2>&1; eq "$?" 2 "a bad step is refused"

echo "== init with a saved volume, and fixed =="
ua volume 100 >/dev/null; : > "$T/log"; ua init >/dev/null 2>&1
grep -q 'PCM Playback Volume 100,100' "$T/log" && ok "init restores the saved volume" || bad "no restore"
ua volume 30 >/dev/null; : > "$T/log"; ua fixed
grep -q 'PCM Playback Volume 100,100' "$T/log" && ok "fixed sets VOLUME_SENDSPIN" || bad "fixed: $(cat "$T/log")"
eq "$(ua volume)" 30 "fixed does not change the saved volume"
echo "$N passed, $F failed"
[ "$F" = 0 ]
