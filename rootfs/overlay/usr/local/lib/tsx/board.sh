# board.sh: the values and the small functions of this board. Shell scripts
# of the panel software source it:
#   . "${TSX_BOARD_CONF:-/usr/local/lib/tsx/board.sh}"
# Each board family has its own file with the same names (the uc-pxx here).
# The shared scripts never test the family. They read these names only.
# The file has plain variables and functions, and it has no side effects when
# a script sources it. A value that is in the environment wins (host tests
# use that). Python reads a value with `tsx-board get NAME`.
#
# This file holds the fixed facts of the board. The parts that a panel may
# lack (microphone, Bluetooth) are not here. tsx-hw detects them at boot into
# /run/tsx/hw.conf.
#
# Variables
#   TSX_FAMILY             family name: uc-pxx
#   TSX_PKG_PREFIX         the prefix of the package names of the family
#                          ($TSX_PKG_PREFIX-board, $TSX_PKG_PREFIX-kernel-lts).
#                          Common builds these names. Without this variable
#                          common uses tsx-$TSX_FAMILY.
#   TSX_APK_CATEGORY       the repository category after the Alpine branch
#                          (<APK_URL>/<branch>/common and .../$TSX_APK_CATEGORY)
#   TSX_HA_MODEL           the model name in Home Assistant when the board has
#                          no better one (the device tree gives the model)
#   TSX_SOUND_CARD         ALSA card name
#   TSX_DISPLAY_DRM        DRM driver names (shell patterns, separated by
#                          spaces) of the display
#   TSX_RENDER_DRM         DRM driver names of GPUs without a display. The
#                          kiosk uses their render node. The display
#                          (rockchip) and the GPU (panfrost) are two DRM
#                          devices on this board.
#   TSX_DISPLAY_ENV        NAME=value words that the kiosk exports when the
#                          display driver is in TSX_DISPLAY_DRM
#   TSX_BT_CHIP            the chip file of tsx-bt, or "none" (the chip needs
#                          no help from user space)
#   TSX_BT_PROXY_DEFAULT   on | off: BT_PROXY when panel.conf leaves it empty
#   TSX_BT_MAC_SETTABLE    yes | no: BT_MAC can set the Bluetooth address
#   TSX_MAC_SOURCE         name of the source of the eth0 MAC (cfg)
#   TSX_SERIAL_CONSOLE     the serial console device name (ttyS2). The
#                          /etc/securetty of this package lists it, so root
#                          can log in there.
#   TSX_RENDER_ENV         NAME=value words for the GPU driver, exported by the
#                          kiosk when a render node exists
#   TSX_BROWSER_GL_FLAGS   extra Chromium flags for GPU rendering
#   TSX_VOLUME_CMD         a command that prints and sets the volume
#   TSX_VOLUME_FIXED_CMD   a command that sets the speaker to its fixed level
#                          while the Sendspin player owns the volume
#   TSX_RESCUE_BACKLIGHT   percent of max_brightness that the rescue system
#                          sets at start (default 50, at most 80)
#   TSX_CONFIG_RELOAD      services that tsx-config apply reloads when the
#                          sensor settings change
#
# Functions (print the value, print nothing when the board has none)
#   tsx_board_model        the model: UC-P10 or UC-P8
#   tsx_board_dt_model     the model of the device tree, from the compatible
#                          crestron,uc-p10 or crestron,uc-p8. It names the
#                          file panel-board.d/<model>.conf.
#   tsx_board_ha_model     the model name for Home Assistant
#   tsx_board_stock_fw     the version of the stock firmware (none here)
#   tsx_board_unit_id      the unit id for file names (the MAC without colons)
#   tsx_board_mac          the MAC that the board gives eth0 (a valid one only)
#   tsx_board_mac_early    the same, for early boot
#   tsx_board_mac_source   TSX_MAC_SOURCE
#   tsx_board_hostname_hint  the host name that the board suggests (none here)
#   tsx_board_rescue_extra extra lines for the rescue screen (none yet)
#   tsx_board_ledbar_map MODEL  the name of the LED map for the USB LED bar
#                          (none here)
#   tsx_board_pre_update   the board hook of tsx-autoupdate. It runs after the
#                          check found packages and BEFORE apk upgrade changes
#                          anything. It runs uc-pxx-arm-slot, which arms slot A
#                          to "trying", so a bad update falls back to slot B
#                          (docs/boot-control.md "The update rule"). When it
#                          exits with a non-zero status, tsx-autoupdate does not
#                          install and keeps the packages pending.
#   tsx_board_load         read the board data once, on a running system
#                          (nothing to read here)
#   tsx_board_probe DIR    point the data reader at the board data from the
#                          rescue system. Always succeeds here.
# Test hooks: TSX_CFG (the cfg partition or a file), TSX_SYSBLOCK, TSX_DEVDIR,
# TSX_DT_COMPATIBLE.

TSX_FAMILY=${TSX_FAMILY:-uc-pxx}
TSX_PKG_PREFIX=${TSX_PKG_PREFIX:-uc-pxx}
TSX_APK_CATEGORY=${TSX_APK_CATEGORY:-uc-pxx}
TSX_HA_MODEL=${TSX_HA_MODEL:-UC-P10}
TSX_SOUND_CARD=${TSX_SOUND_CARD:-UCP10}
TSX_DISPLAY_DRM=${TSX_DISPLAY_DRM:-rockchip}
TSX_RENDER_DRM=${TSX_RENDER_DRM:-panfrost}
TSX_DISPLAY_ENV=${TSX_DISPLAY_ENV-}
# The BCM4345C5 Bluetooth controller attaches as a serdev device of the kernel
# and loads its patch file itself (BCM4345C5.hcd, copied by uc-pxx-firmware).
# So tsx-bt needs no chip file.
TSX_BT_CHIP=${TSX_BT_CHIP:-none}
# tsx-config apply reloads these running services when the sensor settings change.
TSX_CONFIG_RELOAD=${TSX_CONFIG_RELOAD:-uc-pxx-als}
# The address comes from the controller, so BT_MAC cannot apply.
TSX_BT_MAC_SETTABLE=${TSX_BT_MAC_SETTABLE:-no}
# TODO: the Bluetooth proxy is not tested on this board. Turn it on after the test.
TSX_BT_PROXY_DEFAULT=${TSX_BT_PROXY_DEFAULT:-off}
TSX_MAC_SOURCE=${TSX_MAC_SOURCE:-cfg}
TSX_SERIAL_CONSOLE=${TSX_SERIAL_CONSOLE:-ttyS2}
# TODO: Chromium with panfrost is not tested. Fill in the flags that it needs.
TSX_RENDER_ENV=${TSX_RENDER_ENV-}
TSX_BROWSER_GL_FLAGS=${TSX_BROWSER_GL_FLAGS-}
TSX_VOLUME_CMD=${TSX_VOLUME_CMD:-uc-pxx-audio volume}
TSX_VOLUME_FIXED_CMD=${TSX_VOLUME_FIXED_CMD-uc-pxx-audio fixed}
TSX_RESCUE_BACKLIGHT=${TSX_RESCUE_BACKLIGHT:-50}

# tsx_board_load: the board keeps no key/value store. Nothing to read.
tsx_board_load() { return 0; }

# tsx_board_probe DIR: for the rescue system. The data is on partitions, so
# there is nothing to point at.
tsx_board_probe() { return 0; }

# The cfg partition (or the file that a test names). It also holds a private
# key. So the board reads only the six bytes of the MAC from it, read-only, and
# never copies the partition.
tsx_board_cfg_dev() {
	[ -n "${TSX_CFG:-}" ] && { echo "$TSX_CFG"; return 0; }
	for _tb_u in "${TSX_SYSBLOCK:-/sys/class/block}"/mmcblk*p*/uevent; do
		[ -r "$_tb_u" ] && grep -qx 'PARTNAME=cfg' "$_tb_u" || continue
		_tb_d=${_tb_u%/uevent}; echo "${TSX_DEVDIR:-/dev}/${_tb_d##*/}"; return 0
	done
	return 1
}

# The MAC of the unit is in the cfg partition, in bytes 6 to 11. It is valid
# when it is not all zero, not all ones, and a globally administered unicast
# address (bits 0 and 1 of the first byte are clear).
tsx_board_mac() {
	_tb_b=$(tsx_board_cfg_dev) || return 0
	[ -b "$_tb_b" ] || [ -f "$_tb_b" ] || [ -L "$_tb_b" ] || return 0
	_tb_m=$(dd if="$_tb_b" bs=1 skip=6 count=6 2>/dev/null | od -An -tx1 | tr -s ' \n' ':' | sed 's/^://; s/:$//')
	echo "$_tb_m" | grep -qiE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || return 0
	case "$_tb_m" in 00:00:00:00:00:00|ff:ff:ff:ff:ff:ff) return 0;; esac
	[ $(( 0x${_tb_m%%:*} & 3 )) = 0 ] || return 0
	echo "$_tb_m"
	return 0
}
tsx_board_mac_early() { tsx_board_mac; }
tsx_board_mac_source() { echo "$TSX_MAC_SOURCE"; }

# The model of the device tree. The compatible list has crestron,uc-p10 or
# crestron,uc-p8 (the device tree of the UC-P8 may also list the UC-P10).
# The first match in the list wins.
tsx_board_dt_model() {
	_tb_f=${TSX_DT_COMPATIBLE:-/proc/device-tree/compatible}
	[ -r "$_tb_f" ] || return 0
	for _tb_c in $(tr '\0' ' ' < "$_tb_f"); do
		case $_tb_c in
		crestron,uc-p10) echo UC-P10; return 0;;
		crestron,uc-p8) echo UC-P8; return 0;;
		esac
	done
	return 0
}
tsx_board_model() { tsx_board_dt_model; }
# The Home Assistant model is the model of the unit. tsx-mqtt uses
# TSX_HA_MODEL when this prints nothing.
tsx_board_ha_model() { tsx_board_model; }
tsx_board_stock_fw() { return 0; }
tsx_board_unit_id() {
	_tb_m=$(tsx_board_mac)
	if [ -n "$_tb_m" ]; then echo "$_tb_m" | tr -d ':' | tr 'A-F' 'a-f'; else echo unknown; fi
}
tsx_board_hostname_hint() { return 0; }
tsx_board_ledbar_map() { return 0; }
# The board hook of tsx-autoupdate. The status of the function is the status
# of uc-pxx-arm-slot: 0 armed and verified, 1 refused, 3 A/B state unknown.
tsx_board_pre_update() { /usr/sbin/uc-pxx-arm-slot; }
# TODO: show the boot slot and the A/B state on the rescue screen, after the
# boot-control tool exists (docs/boot-control.md).
tsx_board_rescue_extra() { return 0; }
