# LEDs, switches and the ESPHome plugin

The board adds entities to the ESPHome device of the panel with the plugin
`/usr/local/share/tsx/esphome.d/uc-pxx.py`. The plugin interface is in
`docs/esphome.md` of tsx-linux-common. This page tells which entities the
plugin adds and which rules the LEDs follow.

## Entities

The object ids are fixed. Home Assistant keeps the settings of an entity by its
key, and the key comes from the object id. Do not change an object id.

| Entity | Object id | Type | Source |
|---|---|---|---|
| Teams LED | `teams_led` | light, on/off | LED `teams_white`, key LED 1 |
| Headset LED | `headset_led` | light, on/off | LED `mute_headset`, key LED 2 |
| Speaker LED | `speaker_led` | light, on/off | LED `mute_speaker`, key LED 3 |
| Mic mute LED | `mic_mute_led` | light, on/off | LED `mute_red`, key LED 4 |
| Key LEDs release | `key_leds_release` | button | Gives the four LEDs back to tsx-buttons |
| Status LED | `status_led` | light, RGB | LEDs `red`, `green` and `blue` |
| Status LED control | `status_led_control` | text sensor, diagnostic | Who owns the status LED now |
| Handset off-hook | `handset_off_hook` | binary sensor | `SW_DOCK` of `gpio-keys` |
| Camera privacy | `camera_privacy` | binary sensor | `SW_CAMERA_LENS_COVER` of `gpio-keys` |

An entity exists only when its part exists. A panel without the LED class
devices of the key LEDs has no key LED lights. A panel without the switch bit
has no sensor for it. Common adds the light "Key LEDs" itself.

## Who writes the LEDs

The plugin runs as user kiosk when `VOICE` is on. That user cannot write an LED
or talk to tsx-buttons. So the plugin writes one command per line to the FIFO
`/run/tsx/uc-pxx-leds` (group kiosk). The root service `uc-pxx-leds` reads the
FIFO. It runs only these fixed commands and refuses everything else:

| Command | Effect |
|---|---|
| `key N on\|off\|auto` | Runs `tsx-keypad key N STATE`. N is 1 to 4 |
| `keys auto` | The same with `auto` for all four key LEDs |
| `status R G B` | The status LED. R, G and B are 0 or 1 |

The plugin reads the state of the LEDs from `/sys/class/leds`. It never writes
them.

## Key LEDs: the rule

Two controls act on the four key LEDs:

1. The light "Key LEDs" of tsx-buttons sets one level for all LEDs. The LEDs
   are on/off LEDs (`LED_MODE=onoff`), so a level above 0 turns every LED on.
2. The four lights of this plugin set an override for one LED. It is the
   override of `tsx-keypad key N on|off|auto`.

The rules:

- tsx-buttons applies the level and the overrides together. It writes the LEDs
  again every 5 seconds. So a program that writes an LED in `/sys` directly
  loses the value within 5 seconds. That is why the plugin never writes an LED
  itself.
- A light turned off sets the override `off`. The LED stays dark, whatever the
  level of "Key LEDs" is.
- A light turned on sets the override `on`. The LED follows the level of "Key
  LEDs". It is lit while the level is above 0.
- The button "Key LEDs release" sets `auto` for all four LEDs. tsx-buttons then
  owns them again.
- An override stays until the button, `tsx-keypad key N auto` or a restart of
  tsx-buttons. A reboot clears it.
- Each light shows the LED as it is, not the last command. After a command, the
  light keeps the asked state for 2 seconds. Then it shows the LED again. So a
  command that has no effect turns back.

Limit of tsx-buttons today: the override `on` does not force the LED on. With
the level of "Key LEDs" at 0, a light turned on turns back to off after
2 seconds. A status indicator that must light while "Key LEDs" is off needs a
change in tsx-linux-common: the override `on` must light the LED at level 0
too (`on = key_override[i] == 1 || (lvl > 0 && key_override[i] != 0 && ...)` in
`leds_apply`). The plugin does not change when this lands.

## Status LED: the hand-over

The status LED has three on/off LEDs: seven colors and off. The service
`uc-pxx-status-led` shows the boot state on it (blue heartbeat, then green).
Home Assistant takes it over with these rules:

1. Until the boot is marked good, the boot service owns the LED. The service
   writes `boot wait` or `boot ok` to `/run/tsx/status-led.state`. A command
   from Home Assistant is refused until the file says `boot ok`.
2. After that, Home Assistant owns the LED. Turning the light off turns every
   LED off, also the green of the boot. The next boot shows the boot state
   again.
3. The marker `/run/uc-pxx-slot-a-changed` takes the LED away again. The A/B
   scripts create it before they arm or change slot A. While it exists,
   `uc-pxx-leds` refuses status commands.

Why not "always, with the boot service yielding": the blue heartbeat is the
only sign that the boot is not yet marked good. Home Assistant must not hide
it.

### The red LED

The A/B scripts write `/sys/class/leds/red/brightness` when the A/B state is
unknown. Home Assistant must not hide that. `uc-pxx-leds` follows these rules:

- Red that is on at the start, or on and not switched on by `uc-pxx-leds`, is
  latched. The helper never writes a latched red LED. A status command changes
  only green and blue.
- The latch ends only when the red LED reads 0 again. Then a person cleared it.
- The helper writes the red LED only when it reads the value that the helper
  wrote last.
- The light then shows the red LED as lit. Home Assistant sees that its color
  did not take effect. The text sensor "Status LED control" adds "red LED
  latched".

Limit: if Home Assistant lit red itself and a script then lights red, the
change is not visible. Every script that lights red after a change of slot A
creates the marker first, so the status LED is locked then. The hook of
`uc-pxx-mark-boot` lights red only when the boot is not marked good, so the
LED is not under Home Assistant then either.

The text sensor "Status LED control" shows `Home Assistant`, `Boot (...)`,
`Locked (...)` or `Unavailable`.

## Switches

The sensors use the ioctl `EVIOCGSW` on the input device `gpio-keys`, twice per
second at most. They do not wait for events, because `tsx-idled` grabs the
input devices while the screen is blank. The same device is read by
`uc-pxx-presence` for the PIR.

| Sensor | Switch | On when |
|---|---|---|
| Handset off-hook | `SW_DOCK` (5) | the switch is 1 (the handset is lifted) |
| Camera privacy | `SW_CAMERA_LENS_COVER` (9) | the switch is 1 (the lens is covered) |

The polarity of the hook was measured on the UC-P10. With the handset lifted, the
GPIO reads low and the switch is 1. With the handset on the cradle, the switch is
0. If a unit shows it the other way, set `HOOK_OFFHOOK_VALUE=0` in
`/etc/tsx/uc-pxx-esphome.conf`. The camera is not fitted, and the polarity of
the shutter is not measured.

## Presence without a distance

The PIR gives presence and no distance. Common has no way to say this today:

- The Distance sensor of the ESPHome device and of MQTT exists whenever
  `/run/tsx/presence.state` exists. `uc-pxx-presence` writes `distance none`,
  so the sensor shows "unknown". Without the line it would be the same.
- The setup page and `tsx-config` hide `PRESENCE_WAKE`, `PRESENCE_DISTANCE_MM`,
  `PRESENCE_MIN_MM` and `PRESENCE_HOLD_S` together, only for `PRESENCE=no` in
  `hw.conf`. The xx60 has no presence sensor and uses `PRESENCE=no`.

So on this board `PRESENCE_DISTANCE_MM` and `PRESENCE_MIN_MM` show on the setup
page and do nothing. A change in common is needed to hide them and the Distance
sensor, for example a key `DISTANCE=no` in `hw.conf`.

## Tests

| Test | Checks |
|---|---|
| `rootfs/tests/test-esphome-plugin.sh` | The plugin against `tsx_panel` of tsx-linux-common with fake LEDs, a fake input device and a FIFO. Needs `TSX_COMMON` |
| `rootfs/tests/test-leds.sh` | `uc-pxx-leds`: the commands, the gate, the red latch and the FIFO |
| `rootfs/tests/test-status-led.sh` | The state file of `uc-pxx-status-led` |
