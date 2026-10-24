# Hardware

This page lists the parts of the UC-P10 and the state of each in the
mainline kernel. The state comes from the bring-up work on one unit.

## Summary

| Item | UC-P10 |
|---|---|
| SoC | RK3399, 4x Cortex-A53 and 2x Cortex-A72. All six cores have frequency scaling |
| PMIC | RK808, with a SYR827 (rail `vdd_cpu_b`) and a SYR828 (rail `vdd_gpu`) |
| Display | 1200x1920 MIPI DSI, Himax panel, rotated 270 degrees |
| GPU | Mali-T860, panfrost driver, display through rockchip-drm |
| Touch | Atmel mXT1066 on i2c4, with six T15 touch keys |
| LEDs | RGB status LED (green, red, blue) and four key LEDs |
| Audio | AIC3104 codec on I2S0 SDO1 |
| Microphones | A speakerphone pair and a handset microphone |
| Network | GMAC to an RTL8364B switch (LAN port and PC port) |
| Wi-Fi and Bluetooth | AP6256: BCM43456 on SDIO, BCM4345C5 on UART |
| USB | USB-C device port with a fusb302 |
| Light sensor | JSA1213, driver `jsa1212` |
| Not fitted | TAS5825M amplifier and OV2735 camera (the device tree nodes exist) |

## Audio

The ALSA card is called `UCP10`. The I2S0 interface runs four channels for
playback and eight channels for capture.

- Playback channels 1 and 2 go to SDO0, where the TAS5825M would be. The
  amplifier is not fitted on the unit that we used.
- Playback channels 3 and 4 go to SDO1, the AIC3104. Channel 4 (right DAC)
  drives the hands-free speaker amplifier and the handset earpiece amplifier.
  Two GPIO enables select them. Both are on by default.
- Capture channels 1 and 2 are the speakerphone microphones. Channel 3 is the
  handset microphone.
- The first 0.5 s of a capture holds the power-up transient of the ADC.

`rootfs/overlay/etc/asound.conf` maps the stereo default to the four playback
channels and shares the capture device with dsnoop.

## Keys and LEDs

The touch controller reports six touch keys (object T15). The layout below is
user-confirmed. The key order is to verify with evtest. Nobody has pressed the
keys with evtest yet.

| Place (left to right) | Key | Key code | LED |
|---|---|---|---|
| 1 | Teams | `KEY_PROG1` (148) | `teams_white` |
| 2 | Headset | `KEY_PROG2` (149) | `mute_headset` |
| 3 | Speaker | `KEY_PROG3` (202) | `mute_speaker` |
| 4 | Volume down | `KEY_VOLUMEDOWN` (114) | none |
| 5 | Volume up | `KEY_VOLUMEUP` (115) | none |
| 6 | Mic (mute) | `KEY_MUTE` (113) | `mute_red` |

The device tree lists the codes in the order of the T15 key index: 113, 115,
114, 202, 149, 148. The RGB status LED (`green`, `red`, `blue`) is in the
centre at the bottom.

The file `rootfs/overlay/etc/tsx/buttons-board.conf` has the key names and
codes for `tsx-buttons`. The key LEDs are plain on/off LEDs. The LED model of
`tsx-buttons` does not fit them yet ([rootfs.md](rootfs.md)).

To verify the order, run `evtest` on the touch input device and press the
keys from left to right. The codes must appear in the order of the table.

## Network identity

The Ethernet MAC address is in the `cfg` partition, in bytes 6 to 11. That
partition also holds a private key. So the board file reads only these six
bytes, read-only, and never copies the partition. The Wi-Fi and Bluetooth
addresses come from the module.

## Open items

- The RTL8364B switch needs an init in user space or in a kernel driver.
  The kernel driver `realtek-rtl8364b-smi` only gives access to the switch
  registers. Today `tools/rtl8363-init` does the init. See [rootfs.md](rootfs.md).
- The handset volume shares the DAC with the speaker. A separate volume for
  each output needs a codec route change.
- The USB-C port had no VBUS partner on the unit that we used. It is not
  tested.
- The IEP image processor has no mainline driver.
- DDR frequency scaling stays off. It is not proven safe.
- Big-core hot-plug after boot does not work. The kernel boots all cores.
- The UC-P8 needs its own panel driver (ILI9881C-type init from the stock
  device tree) and its own device tree.
