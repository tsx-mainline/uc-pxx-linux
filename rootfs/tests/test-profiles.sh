#!/bin/sh
# Host test for the image profiles (rootfs/profiles/*.list, rootfs/profile.sh).
# It needs no compiler, no container and no panel. It runs the same
# profile.sh that mkrootfs.sh calls, and so checks what each image holds:
#   - every package is in exactly one list
#   - ha (the default) has the packages, services and users of the full image
#   - console has no Home Assistant, MQTT, ESPHome, voice, Sendspin or Chromium
#     package or service, and no kiosk or setup page
#   - kiosk has the browser and no Home Assistant part
#   - the files that the image keeps (image.list): fstab, inittab and the
#     profile marker. The packages own all other files
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PS=$HERE/profile.sh
OV=$HERE/overlay
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== syntax =="
busybox sh -n "$PS" && ok "profile.sh passes busybox sh -n" || bad "profile.sh: busybox sh -n"
busybox sh -n "$HERE/mkrootfs.sh" && ok "mkrootfs.sh passes busybox sh -n" || bad "mkrootfs.sh: busybox sh -n"
busybox sh -n "$HERE/fetch-apk-tree.sh" && ok "fetch-apk-tree.sh passes busybox sh -n" || bad "fetch-apk-tree.sh: busybox sh -n"
busybox sh -n "$HERE/check-apk-tree.sh" && ok "check-apk-tree.sh passes busybox sh -n" || bad "check-apk-tree.sh: busybox sh -n"
bash -n "$HERE/build-rootfs.sh" && ok "build-rootfs.sh passes bash -n" || bad "build-rootfs.sh: bash -n"

# the build container runs profile.sh with busybox ash and busybox awk
for p in console kiosk ha; do
	eq "$(busybox sh "$PS" entries $p | md5sum)" "$(sh "$PS" entries $p | md5sum)" "busybox gives the same entries as sh for $p"
done

echo "== the lists hold only entries that the build uses =="
kinds=$(for l in console kiosk ha; do awk '/^[ \t]*(#|$)/ { next } { print $1 }' "$HERE/profiles/$l.list"; done | sort -u | tr '\n' ' ')
eq "$kinds" "pkg step svc user " "the lists use the kinds pkg, step, svc and user"
for l in console kiosk ha; do awk '$1 == "step" { print $2 }' "$HERE/profiles/$l.list"; done | sort > "$T/steps"
for s in $(cat "$T/steps"); do
	grep -q "has step $s" "$HERE/mkrootfs.sh" || [ "$s" = firmware ] || [ "$s" = ssh-policy ] || [ "$s" = root-password ] && ok "step $s is known" || bad "step $s: nothing in mkrootfs.sh asks for it"
done
grep -qx qbootctl "$T/steps" && bad "a list has the step qbootctl (this board has no qbootctl)" || ok "no list has the step qbootctl"

echo "== every package is in exactly one list =="
for l in console kiosk ha; do awk '$1 == "pkg" { print $2 }' "$HERE/profiles/$l.list"; done | sort > "$T/pkgs"
eq "$(uniq -d "$T/pkgs")" "" "no package is in two lists"
for f in packages.txt packages-tsx.txt; do grep -v '^#' "$HERE/$f" | sed 's/=.*//' | grep -v '^$'; done | sort > "$T/pkgfiles"
eq "$(comm -3 "$T/pkgs" "$T/pkgfiles" | tr -d '\t' | tr '\n' ' ')" "" "the lists and packages.txt, packages-tsx.txt name the same packages"

echo "== ha: the full image =="
for f in packages.txt packages-tsx.txt; do
	grep -v '^#' "$HERE/$f" > "$T/all.$f"
	sh "$PS" packages ha "$HERE/$f" > "$T/ha.$f"
	cmp -s "$T/all.$f" "$T/ha.$f" && ok "$f: same lines in the same order" || bad "$f: ha differs from the file"
done
want_default="networking chronyd sshd seatd crond uc-pxx-audio uc-pxx-als tsx-buttons tsx-idled tsx-panelctl tsx-bt dbus avahi-daemon tsx-sendspin tsx-esphome tsx-mqtt tsx-autoupdate tsx-setup-helper tsx-setupd kiosk uc-pxx-boot-ok local"
eq "$(sh "$PS" entries ha svc | awk '$1 == "default" { print $2 }' | sort | tr '\n' ' ')" "$(echo $want_default | tr ' ' '\n' | sort | tr '\n' ' ')" "ha: the services of the default runlevel"
eq "$(sh "$PS" entries ha svc | awk '$1 == "boot" { print $2 }' | sort | tr '\n' ' ')" "tsx-config tsx-data tsx-hostname tsx-setup uc-pxx-firmware uc-pxx-lvm uc-pxx-switch uc-pxx-watchdog " "ha: the services of the boot runlevel"
eq "$(sh "$PS" entries ha user | sort | tr '\n' ' ')" "kiosk tsx-setup " "ha: the users"
for s in firmware lva; do sh "$PS" has ha step $s && ok "ha: build step $s" || bad "ha: no build step $s"; done

echo "== console =="
for s in lva; do sh "$PS" has console step $s && bad "console: build step $s" || ok "console: no build step $s"; done
pk=$( { sh "$PS" packages console "$HERE/packages.txt"; sh "$PS" packages console "$HERE/packages-tsx.txt"; } | grep -E 'chromium|mosquitto|py3-(zeroconf|numpy|protobuf|cryptography|tzlocal|aiohappyeyeballs|mpv)|mpv|sendspin|tensorflow|sway|seatd|cage|wlroots|squeekboard|wvkbd|mesa|libinput|compat-libdns' )
eq "$pk" "" "no browser, compositor, voice, MQTT or Sendspin package"
for p in openssh-server busybox tsx-keys uc-pxx-kernel-lts alsa-utils bluez-deprecated python3 lvm2; do
	sh "$PS" has console pkg $p && ok "console keeps package $p" || bad "console lacks package $p"
done
sv=$(sh "$PS" entries console svc | awk '{ print $2 }' | grep -E 'kiosk|setup-helper|setupd|mqtt|esphome|sendspin|voice|^tsx-bt$|seatd')
eq "$sv" "" "no kiosk, setup page, HA or seat service"
for s in sshd tsx-config tsx-autoupdate uc-pxx-audio tsx-panelctl tsx-idled tsx-buttons uc-pxx-boot-ok uc-pxx-switch uc-pxx-firmware; do
	sh "$PS" has console svc $s && ok "console keeps service $s" || bad "console lacks service $s"
done
eq "$(sh "$PS" entries console user | tr '\n' ' ')" "" "console has no kiosk or setup user"
grep -q pkgsvc "$HERE/mkrootfs.sh" && bad "mkrootfs.sh still reads pkgsvc lines" || ok "mkrootfs.sh has no pkgsvc lines (every service comes from a package)"

echo "== kiosk =="
for p in chromium sway seatd squeekboard; do sh "$PS" has kiosk pkg $p && ok "kiosk has package $p" || bad "kiosk lacks package $p"; done
sh "$PS" has kiosk svc kiosk && ok "kiosk starts the kiosk service" || bad "kiosk: no kiosk service"
for s in tsx-mqtt tsx-esphome tsx-sendspin tsx-bt; do sh "$PS" has kiosk svc $s && bad "kiosk starts $s" || ok "kiosk does not start $s"; done
for p in mosquitto-clients py3-zeroconf sendspin-cli tensorflow-lite-c; do sh "$PS" has kiosk pkg $p && bad "kiosk has package $p" || ok "kiosk has no package $p"; done
sh "$PS" has kiosk step lva && bad "kiosk: build step lva" || ok "kiosk: no build step lva"

echo "== image.list: the files that the image keeps =="
imgs=$(awk '/^[ \t]*(#|$)/ { next } $1 == "image" { print $2 }' "$HERE/profiles/image.list" | sort | tr '\n' ' ')
eq "$imgs" "etc/fstab etc/inittab etc/tsx/profile " "image.list names fstab, inittab and the profile marker"
for f in $imgs; do [ -e "$OV/$f" ] || [ -e "$HERE/profiles/console/overlay/$f" ] || bad "image.list: $f is nowhere"; done
for p in console kiosk ha; do
	rm -rf "$T/img-$p"; sh "$PS" stage $p "$T/img-$p" >/dev/null
	got=$(cd "$T/img-$p" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')
	case $p in ha) want="etc/fstab etc/inittab ";; *) want="etc/fstab etc/inittab etc/tsx/profile ";; esac
	eq "$got" "$want" "stage $p copies only the image files"
done
cmp -s "$T/img-console/etc/inittab" "$HERE/profiles/console/overlay/etc/inittab" && ok "console: the console inittab" || bad "console: wrong inittab"
cmp -s "$T/img-kiosk/etc/inittab" "$OV/etc/inittab" && ok "kiosk: the kiosk inittab" || bad "kiosk: wrong inittab"
cmp -s "$T/img-ha/etc/inittab" "$OV/etc/inittab" && ok "ha: the kiosk inittab" || bad "ha: wrong inittab"
cmp -s "$T/img-ha/etc/fstab" "$OV/etc/fstab" && ok "fstab comes from the overlay" || bad "wrong fstab"
eq "$(cat "$T/img-console/etc/tsx/profile")" console "console has the marker /etc/tsx/profile"
eq "$(cat "$T/img-kiosk/etc/tsx/profile")" kiosk "kiosk has the marker /etc/tsx/profile"
[ ! -e "$T/img-ha/etc/tsx/profile" ] && ok "ha has no profile marker (a missing marker means ha)" || bad "ha has a profile marker"
grep -Eq '^tty1::respawn:/sbin/getty ' "$T/img-console/etc/inittab" && ok "console: getty on tty1" || bad "console: no getty on tty1"
for p in console kiosk ha; do
	grep -Eq '^::respawn:.*getty -L 115200 ttyS2' "$T/img-$p/etc/inittab" && ok "$p: getty on the serial port" || bad "$p: no serial getty"
done
for p in kiosk ha; do
	grep -Eq '^tty[0-9]::' "$T/img-$p/etc/inittab" && bad "$p: getty on tty1" || ok "$p: no getty on tty1 (the browser owns the screen)"
done
# a profile file wins over a file of the overlay at the same path
mkdir -p "$T/pd/ha/overlay/etc" "$T/ov/etc"; echo overlay > "$T/ov/etc/fstab"; echo profile > "$T/pd/ha/overlay/etc/fstab"
printf 'image etc/fstab\n' > "$T/pd/image.list"
cp "$HERE/profiles/console.list" "$HERE/profiles/kiosk.list" "$HERE/profiles/ha.list" "$T/pd/"
TSX_PROFILE_DIR=$T/pd TSX_OVERLAY_DIR=$T/ov sh "$PS" stage ha "$T/win" >/dev/null
eq "$(cat "$T/win/etc/fstab")" profile "a file of the profile wins over the file of the overlay"
rm -rf "$T/win"; rm "$T/pd/ha/overlay/etc/fstab"
TSX_PROFILE_DIR=$T/pd TSX_OVERLAY_DIR=$T/ov sh "$PS" stage ha "$T/win" >/dev/null
eq "$(cat "$T/win/etc/fstab")" overlay "without a profile file, the file of the overlay is used"
# a link in the profile folder is followed
rm -rf "$T/win"; echo linked > "$T/target"; ln -s "$T/target" "$T/pd/ha/overlay/etc/fstab"
TSX_PROFILE_DIR=$T/pd TSX_OVERLAY_DIR=$T/ov sh "$PS" stage ha "$T/win" >/dev/null
[ ! -L "$T/win/etc/fstab" ] && eq "$(cat "$T/win/etc/fstab")" linked "stage follows a link: the image holds the file" || bad "stage keeps a link"
# the old commands are gone
sh "$PS" stage-image ha "$T/x" >/dev/null 2>&1 && bad "stage-image still exists" || ok "stage-image is gone (stage copies the image files only)"
sh "$PS" unclassified >/dev/null 2>&1 && bad "unclassified still exists" || ok "unclassified is gone"

echo "== usage errors =="
sh "$PS" includes nothing >/dev/null 2>&1 && bad "an unknown profile is accepted" || ok "an unknown profile is refused"

echo "$N passed, $F failed"
[ "$F" = 0 ]
