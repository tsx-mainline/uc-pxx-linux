# LEDs

The UC-P10 has seven LEDs. They are status indicators, not key backlights.
The package `uc-pxx-leds` owns all of them. The daemon `uc-pxx-leds` is the
only program that writes them. `tsx-buttons` does not touch them. Two
exceptions come before the daemon: the kernel (the device tree trigger of the
blue LED) and `/init` of the initramfs (the blink timing of the blue LED), see
"The boot timeline of the blue LED".

| LED class device | What it is | Name in this package |
|---|---|---|
| `teams_white` | Indicator of the Teams key | `teams` |
| `mute_headset` | Indicator of the Headset key | `headset` |
| `mute_speaker` | Indicator of the Speaker key | `speaker` |
| `mute_red` | Indicator of the Mic key (the mic mute LED) | `mic` |
| `red`, `green`, `blue` | The RGB status LED, centre bottom | `status` |

All seven are on/off LEDs (`max_brightness` 1). The status LED makes its seven
colors by mixing the three LEDs. Do not confuse `mute_red` (the Mic indicator)
with `red` (the red part of the status LED).

## Package

The source is in `packages/uc-pxx-leds/`. The package is self-contained. It
will become the aports package `uc-pxx-leds`. The list `FILES` has every file
with its mode. The tree `root/` has the install paths.

| Installed file | Use |
|---|---|
| `/usr/local/sbin/uc-pxx-leds` | The daemon (Python, root, OpenRC) |
| `/etc/init.d/uc-pxx-leds` | The OpenRC service (default runlevel, before `uc-pxx-boot-ok`) |
| `/usr/local/bin/uc-pxx-led` | The command line tool |
| `/etc/tsx/uc-pxx-leds.conf` | The settings (`PERSIST`, `READY_SOURCE`, `READY_TIMEOUT_S`, `BOOT_OK_HOLD_S`) |
| `/usr/local/share/tsx/esphome.d/uc-pxx-leds.py` | The ESPHome plugin |

The package needs `python3`, `openrc` and `uc-pxx-boot-tools` (the program
`uc-pxx-bootctl`). The old service `uc-pxx-status-led` is gone. The daemon does
its work.

## States

An indicator has one of these states. All indicators are off after a boot.

| State | Meaning |
|---|---|
| `off` | Dark |
| `on` | Lit |
| `blink slow` | 1 Hz (500 ms on, 500 ms off) |
| `blink fast` | 4 Hz (125 ms on, 125 ms off) |

The status LED has a color and a mode.

| Color | LEDs on |
|---|---|
| `off` | none |
| `red`, `green`, `blue` | that LED |
| `yellow` | red and green |
| `cyan` | green and blue |
| `magenta` | red and blue |
| `white` | all three |

| Mode | Meaning |
|---|---|
| `solid` | The color stays on |
| `blink` (`slow` or `fast`) | The color blinks |
| `heartbeat` | Two short pulses, then a pause |

The daemon uses the kernel triggers `timer` and `heartbeat` where it can. A
color with a red part is different. The daemon never puts a trigger on the
`red` LED (see "Red LED safety latch"). It makes the pattern itself with plain
writes. The same is true for an LED that has no such trigger.

## Boot display

Two separate states drive the status LED. The boot state is the A/B mark. READY
means that the system is up and the kiosk page shows. The boot display ends
when the system is READY, not when slot A is marked. The mark comes later
(about 61 seconds after the start, after the 60 second health wait).

| Display | Status LED |
|---|---|
| Not READY | Blue, slow blink (500 ms on, 1500 ms off) |
| READY | Green, solid for 10 seconds, then off |
| Boot state `locked` | Blue, slow blink, also after READY |

The slow blink uses the kernel trigger `timer` (`delay_on` 500, `delay_off`
1500), or the same timing in software. After the green time the LED stays dark
in normal use. `BOOT_OK_HOLD_S` in `/etc/tsx/uc-pxx-leds.conf` sets the green
time in seconds (default 10). `BOOT_OK_HOLD_S=0` keeps the green on. The green
time starts when READY becomes true, also after a restart of the daemon.

### The boot timeline of the blue LED

The blue LED blinks from early in the boot, not from the daemon start:

| Time | What blinks the blue LED |
|---|---|
| About 1 s | The LED driver probes. The device tree gives the blue LED the trigger `timer` (`linux,default-trigger`). The kernel default is 500 ms on, 500 ms off. The green and red LEDs have no trigger and stay off |
| `/init` | `/init` sets `delay_on` 500 and `delay_off` 1500, the slow blink of the daemon. In the rescue system `/init` sets 250 ms on and 250 ms off (a fast blink), because no daemon runs there |
| Default runlevel | `uc-pxx-leds` starts. If the system is not READY and the blue LED already has the trigger `timer` with 500 and 1500, the daemon does not write the trigger or the delays. The blink goes on with no gap and no restart |
| READY | The daemon shows green for `BOOT_OK_HOLD_S` seconds, then switches the LED off |

If the blue LED has another trigger or other delays, the daemon sets the
boot blink as before.

### READY

`READY_SOURCE` in the config file picks how the daemon finds READY:

| Value | READY is true when |
|---|---|
| `kiosk` | `/run/tsx/kiosk.ready` exists. `tsx-kiosk-reveal` writes it when the page has painted (`docs/layout.md` of tsx-linux-common) |
| `openrc` | OpenRC has finished the default runlevel: `rc-status -r` says `default` and no service is `starting`. Without `rc-status`, the file `/run/openrc/started/local` exists |
| `bootctl` | The boot state is `ok`. This is the old behavior |
| `auto` | The default. `kiosk` if the service `kiosk` is in the default runlevel (the link `/etc/runlevels/default/kiosk`), else `openrc` |

With `kiosk` and `openrc`, READY is latched. When it is true once, it stays
true while the daemon runs. A later kiosk restart does not bring the blue blink
back. The state file line `ready` says `wait`, `yes` or `fallback`.

`READY_TIMEOUT_S` (default 180) is the fallback. If READY is not true that many
seconds after the daemon started, the daemon goes by the A/B mark, as with
`bootctl`: the blue blink ends when the boot state is `ok`. The line `ready`
says `fallback` then. The daemon polls for READY every 2 seconds.

### Boot state

The daemon reads the boot state with `uc-pxx-bootctl status`. This command only
reads the A/B sector. The daemon asks every 10 seconds while the state is not
`ok`, and every 60 seconds after that. Slot A is successful when the line
`current: A{... succ 1}` shows it. A failed read or a missing line is `wait`.

| Boot state | Meaning |
|---|---|
| `wait` | Slot A is not marked successful |
| `ok` | Slot A is marked successful |
| `locked` | A script changed or armed slot A in this boot |

The state is `locked` while the marker `/run/uc-pxx-slot-a-changed` exists.
`uc-pxx-arm-slot` creates the marker before it arms slot A. The running image
then has not been proven good. The state goes back to `ok` when the marker is
gone and `uc-pxx-bootctl` says that slot A is successful.

The control of the status LED depends on the boot state only, for every
`READY_SOURCE`. Until the state is `ok`, the daemon refuses every `status`
command, except `status auto`. The indicators work in every state. After the
state is `ok`, a `status` command changes the status LED, but the LED shows it
only after READY. `status auto` goes back to the boot display: green until the
end of the green time, then off. A state `wait` with READY (the page is up and
the mark is not yet there) shows the green time, then the LED goes off and the
commands stay locked.

## Red LED safety latch

The A/B scripts write `/sys/class/leds/red/brightness` when the A/B state is
unknown ([boot-control.md](boot-control.md)). Nothing may hide that. The daemon
follows these rules:

- The red LED is latched when it is on at the start of the daemon. It is also
  latched when it is on and the daemon did not switch it on.
- The daemon never writes a latched red LED. A status command changes only the
  green and blue parts.
- The latch ends only when the red LED reads 0 again. A person cleared it.
- The daemon writes red only after it read the value that it wrote last. It
  never turns off a red that it did not turn on.
- While the boot state is `wait` or `locked`, the daemon does not write red at
  all, also when the system is READY.
  A red that the user asked for stays as it is. This closes the race with a
  script that lights red just after it creates the marker.
- The daemon never puts a kernel trigger on `red`. A write to `brightness` of
  an LED with the `timer` trigger would be invisible. With plain writes, every
  change by another program shows.

The state file has the line `red free` or `red latched`. The status LED then
shows red as lit, whatever color was asked.

## Control

The daemon listens on the unix socket `/run/tsx/uc-pxx-leds.sock`. The owner is
root, the group is `kiosk` and the mode is 0660. So the ESPHome plugin, which
runs as user `kiosk`, can use it. A client sends one line and reads one answer
line. The answer is `ok` or `err REASON`. The daemon closes the connection. It
waits at most 2 seconds for a line.

The daemon accepts only these lines and refuses all others:

| Line | Effect |
|---|---|
| `ind NAME on` or `off` | NAME is `teams`, `headset`, `speaker` or `mic` |
| `ind NAME blink [slow\|fast]` | Blink. The default is slow |
| `status auto` | The boot display (off after the green time) |
| `status off` | All three LEDs off |
| `status COLOR [solid\|heartbeat]` | A color |
| `status COLOR blink [slow\|fast]` | A blinking color |
| `get` | The text of the state file |

A line has at most 64 printable ASCII characters. The daemon writes the state
file before it answers. So a client that reads the file after the answer sees
the new state.

### The command line

```
uc-pxx-led <teams|headset|speaker|mic> <on|off|blink> [slow|fast]
uc-pxx-led status auto
uc-pxx-led status off
uc-pxx-led status <colour> [solid|heartbeat]
uc-pxx-led status <colour> blink [slow|fast]
uc-pxx-led show
```

`show` prints the boot state, READY, the four indicators, the status LED (shown and
asked), the red latch and the persistence setting. Without a daemon, it prints
the last state file. The exit status is 0 for done, 1 when the daemon refused
the command, 2 for wrong use and 3 when the daemon does not answer.

### The state file

The daemon writes `/run/tsx/uc-pxx-leds.state` (mode 0644) in one step. Other
programs read it. Each line is a key and its words:

| Line | Values |
|---|---|
| `boot` | `ok`, `wait` or `locked` |
| `ready` | `wait` (not READY), `yes` or `fallback` (the timeout passed and the A/B mark ended the blue blink) |
| `red` | `free` or `latched` |
| `teams`, `headset`, `speaker`, `mic` | `off`, `on` or `blink slow\|fast` |
| `status` | `auto`, or the asked color, mode and speed |
| `shown` | The color and mode that the status LED shows now, for example `green solid`, `off solid` or `blue blink boot` (the slow blink of the boot display). A latched red LED is in the color |
| `persist` | `yes` or `no` |

### Persistence

`PERSIST=yes` in `/etc/tsx/uc-pxx-leds.conf` keeps the state over a reboot.
The default is `no`. The daemon then saves the commands in
`/data/uc-pxx-leds.saved` after each change, and plays them back at the next
start. A saved `status` command takes effect only after the boot is good. The
saved file is plain text with the same lines as the commands. A line that does
not parse is skipped. `rc-service uc-pxx-leds reload` reads the settings
again (`PERSIST`, `BOOT_OK_HOLD_S`, `READY_SOURCE` and `READY_TIMEOUT_S`).

## ESPHome plugin

The plugin `/usr/local/share/tsx/esphome.d/uc-pxx-leds.py` follows the plugin
interface of tsx-linux-common (`docs/esphome.md`). Home Assistant keeps the
settings of an entity by its key, and the key comes from the object id. The
object ids did not change when the LEDs moved to this package.

| Entity | Object id | Type | Daemon |
|---|---|---|---|
| Teams LED | `teams_led` | light, on/off | `ind teams` |
| Headset LED | `headset_led` | light, on/off | `ind headset` |
| Speaker LED | `speaker_led` | light, on/off | `ind speaker` |
| Mic mute LED | `mic_mute_led` | light, on/off | `ind mic` |
| Status LED | `status_led` | light, RGB, with effects | `status` |
| Status LED control | `status_led_control` | text sensor, diagnostic | The `boot` and `red` lines |

The button `key_leds_release` is gone. It gave the key LEDs back to
`tsx-buttons`, and `tsx-buttons` has no LEDs on this board now.

- The plugin reads the state file and sends the commands to the socket. It
  never writes an LED. A blinking indicator shows as on.
- The class `LEDLightEntity` of linux-voice-assistant lists its entity as a
  configuration entity. The plugin sets the entity category to none in the
  entity list. So Home Assistant shows the lights as normal controls.
- The Status LED light has 7 colors. A color that Home Assistant sends is
  rounded: a channel is on when it is at least half of the brightest channel.
  A turn on with black gives white.
- The effects of the Status LED are `Solid`, `Blink`, `Fast blink` and
  `Heartbeat`. The light turned off sends `status off`.
- Until the boot is good, the daemon refuses the status commands. The light
  then shows the real state again at the next poll (the slow blue blink, shown
  as the effect `Blink`).
- The text sensor says `Free`, `Boot (...)`, `Locked (...)` or `Unavailable`,
  with `, red LED latched` added when it applies.
- A command waits for the answer of the daemon for at most half a second.
- A panel without the LED class devices of a light has no entity for it.
- The ESPHome device needs a reconnect in Home Assistant to list entities that
  are new. The entities in this table were there before.

## Later: the Mic key and the mute LED

The Mic key (`KEY_MUTE`) fires a Home Assistant event and does nothing else.
The Mic indicator does not follow the mute state of the microphone. A local
rule in `tsx-buttons` or in a small service can add this: a press of the key
toggles the mute and runs `uc-pxx-led mic on` or `uc-pxx-led mic off`. The
interface above is enough for that. The rule is not part of this package yet.

## Switches

The board plugin `/usr/local/share/tsx/esphome.d/uc-pxx.py` adds two binary
sensors. The sensors use the ioctl `EVIOCGSW` on the input device `gpio-keys`, twice per
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

The PIR gives presence and no distance. The `tsx-hw` of this board writes
`PRESENCE=pir` to `hw.conf`. Common then does this:

- The ESPHome device and MQTT have the Presence sensor and no Distance sensor.
  `tsx-mqtt` clears the Distance discovery topic. The object ids and keys of
  the other entities do not change.
- The setup page and `tsx-config` use `PRESENCE_WAKE` and `PRESENCE_HOLD_S`.
  They hide `PRESENCE_DISTANCE_MM` and `PRESENCE_MIN_MM`, and `apply` leaves
  them out of `/run/tsx/sensors.conf`.

`uc-pxx-presence` writes no `distance` line. The rule is in
`docs/layout.md` of tsx-linux-common ("Presence sensor kind"). It needs a
tsx-linux-common version with that rule.

## Tests

| Test | Checks |
|---|---|
| `packages/uc-pxx-leds/tests/test-package.sh` | `FILES` and the tree are the same. No other file writes the LEDs |
| `packages/uc-pxx-leds/tests/test-daemon.sh` | The daemon with fake LEDs and a stub of `uc-pxx-bootctl`: the commands, the boot state, READY (the sources and the timeout), the colors, the triggers, the red latch, persistence and the socket |
| `packages/uc-pxx-leds/tests/test-cli.sh` | `uc-pxx-led` against the real daemon: commands, exit status, `show` |
| `packages/uc-pxx-leds/tests/test-plugin.sh` | The plugin against `tsx_panel` of tsx-linux-common with stand-ins and a fake daemon. Needs `TSX_COMMON` |
| `rootfs/tests/test-esphome-plugin.sh` | The board plugin `uc-pxx.py` (the switches). Needs `TSX_COMMON` |
| `rootfs/tests/test-board.sh` | `buttons-board.conf` has the six keys and no LED setting |
