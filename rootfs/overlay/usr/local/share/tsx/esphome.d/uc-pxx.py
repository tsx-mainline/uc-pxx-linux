# SPDX-License-Identifier: GPL-2.0-or-later
"""uc-pxx.py: the ESPHome plugin of the uc-pxx board (UC-P10 and UC-P8).

It follows the plugin interface of tsx-linux-common (docs/esphome.md
"Plugins") and adds these entities to the ESPHome device:

  Teams LED, Headset LED, Speaker LED, Mic mute LED   lights (on/off)
  Key LEDs release                                    button
  Status LED                                          light (RGB, 7 colors)
  Status LED control                                  text sensor (diagnostic)
  Handset off-hook                                    binary sensor
  Camera privacy                                      binary sensor

The rules for the LEDs are in docs/leds.md of the uc-pxx-linux repository.
In short:

  - The light "Key LEDs" of tsx-buttons sets the level of all key LEDs. The
    four lights here are an override for one key LED each, the same override
    as `tsx-keypad key N on|off|auto`. Off keeps the LED dark. On lets the LED
    follow the level of "Key LEDs". The button "Key LEDs release" gives all
    four LEDs back to tsx-buttons (auto). Each light shows the LED as it is.
  - The status LED is under the control of the boot service until the boot is
    marked good. After that Home Assistant can set its color. The red LED of
    the boot-control scripts stays on whatever Home Assistant sends.

The plugin may run as user kiosk (VOICE=on). That user cannot write an LED, so
every change goes as one line to the FIFO of the root helper uc-pxx-leds. The
plugin only reads the LED state from /sys/class/leds and the switches from the
input device gpio-keys.

The switches are read with the ioctl EVIOCGSW, once or twice a second. tsx-idled
opens every input device and grabs it while the screen is blank, so a reader of
events would miss changes. The ioctl works with a grabbed device.

Environment overrides for tests: UC_PXX_LEDS (the LED class folder),
UC_PXX_LEDS_FIFO, UC_PXX_LEDS_STATE, UC_PXX_SYS_INPUT, UC_PXX_DEV_INPUT,
UC_PXX_ESPHOME_CONF and TSX_RUN_DIR.
"""

import fcntl
import glob
import logging
import os
import time

from linux_voice_assistant.entity import LEDLightEntity
from tsx_panel.entities import ENTITY_CATEGORY_DIAGNOSTIC, BinarySensorEntity, ButtonEntity, TextSensorEntity

_LOGGER = logging.getLogger("uc_pxx.esphome")

RUN = os.environ.get("TSX_RUN_DIR", "/run/tsx")
LEDS = os.environ.get("UC_PXX_LEDS", "/sys/class/leds")
FIFO = os.environ.get("UC_PXX_LEDS_FIFO", os.path.join(RUN, "uc-pxx-leds"))
LEDS_STATE = os.environ.get("UC_PXX_LEDS_STATE", os.path.join(RUN, "uc-pxx-leds.state"))
SYS_INPUT = os.environ.get("UC_PXX_SYS_INPUT", "/sys/class/input")
DEV_INPUT = os.environ.get("UC_PXX_DEV_INPUT", "/dev/input")
CONF = os.environ.get("UC_PXX_ESPHOME_CONF", "/etc/tsx/uc-pxx-esphome.conf")

INPUT_NAME = "gpio-keys"
SW_DOCK = 5                    # the hook switch
SW_CAMERA_LENS_COVER = 9       # the camera shutter
SW_BYTES = 8
# The hook switch (SW_DOCK) has this value while the handset is lifted. Measured
# on the UC-P10 (2026-10-24): lifted, the GPIO reads low and SW_DOCK is 1 (the key
# is active low). On the cradle, SW_DOCK is 0. HOOK_OFFHOOK_VALUE=0 in CONF
# changes it.
HOOK_OFFHOOK_VALUE = 1
READ_EVERY = 0.25              # seconds between two ioctl calls
HOLD = 2.0                     # seconds that a command holds the shown state

# The key LEDs: (object id, name, LED class device, number of the key LED)
KEY_LED_DEFS = (
    ("teams_led", "Teams LED", "teams_white", 1),
    ("headset_led", "Headset LED", "mute_headset", 2),
    ("speaker_led", "Speaker LED", "mute_speaker", 3),
    ("mic_mute_led", "Mic mute LED", "mute_red", 4),
)
STATUS_LEDS = ("red", "green", "blue")     # the order of the bits in "status R G B"


def _read(path):
    try:
        with open(path, "r", encoding="utf-8") as fobj:
            return fobj.read().strip()
    except OSError:
        return None


def _send(line):
    """One command line to the FIFO of uc-pxx-leds. Never blocks: without a
    reader, the open fails at once."""
    try:
        fdesc = os.open(FIFO, os.O_WRONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0))
    except OSError as err:
        _LOGGER.warning("uc-pxx-leds is not listening (%s): %s", FIFO, err)
        return False
    try:
        os.write(fdesc, (line + "\n").encode("ascii"))
    except OSError as err:
        _LOGGER.warning("cannot write to %s: %s", FIFO, err)
        return False
    finally:
        os.close(fdesc)
    return True


def led_on(name):
    """True while the LED class device shows light: brightness above 0, or a
    trigger other than none (the blue heartbeat of the boot)."""
    base = os.path.join(LEDS, name)
    try:
        if int(_read(os.path.join(base, "brightness")) or "0") > 0:
            return True
    except ValueError:
        pass
    trigger = _read(os.path.join(base, "trigger")) or ""
    for word in trigger.split():
        if word.startswith("[") and word.endswith("]"):
            return word[1:-1] != "none"
    return False


def led_exists(name):
    return os.path.isdir(os.path.join(LEDS, name))


class _HoldLight(LEDLightEntity):
    """A light whose state comes from the hardware. A command holds the state
    that Home Assistant asked for during HOLD seconds, so the next poll does not
    flip it back before the helper has acted. A color of Home Assistant has the
    brightest channel at 1.0 and the brightness alone sets the level, so the
    entity reports color_brightness 1.0, as PanelLight of the device does."""

    def __init__(self, *args, **kwargs):
        LEDLightEntity.__init__(self, *args, **kwargs)
        self._hold_until = 0.0
        self._state = None

    def _hold(self):
        """Call it after a command: hold the state that Home Assistant asked
        for. _state is that state, so the first poll after the hold sends the
        real state if the hardware differs (a refused command)."""
        self._hold_until = time.monotonic() + HOLD
        self._state = self._wanted()

    def _wanted(self):
        raise NotImplementedError

    def _state_response(self):
        response = super()._state_response()
        response.color_brightness = 1.0
        return response

    def _shown(self):
        raise NotImplementedError

    def poll(self):
        if time.monotonic() < self._hold_until:
            return None
        shown = self._shown()
        if shown is None:
            return None
        self._apply(shown)
        self._state = shown
        return self._state_response()


class KeyLedLight(_HoldLight):
    """One key LED as an on/off light: the override `tsx-keypad key N on|off`."""

    def __init__(self, server, key, name, object_id, led, number):
        _HoldLight.__init__(self, server, key, name, object_id, supports_rgb=False,
                            supports_brightness=False, icon="mdi:led-on")
        self.led, self.number = led, number
        self.is_on = led_on(led)
        self._state = (self.is_on,)
        self.update_on_changed(self._changed)

    def _wanted(self):
        return (self.is_on,)

    def _changed(self):
        self._hold()
        _send("key %d %s" % (self.number, "on" if self.is_on else "off"))

    def _shown(self):
        return (led_on(self.led),)

    def _apply(self, shown):
        self.is_on = shown[0]


class StatusLight(_HoldLight):
    """The RGB status LED from three on/off LEDs: 7 colors and off."""

    def __init__(self, server, key):
        _HoldLight.__init__(self, server, key, "Status LED", "status_led", supports_rgb=True,
                            supports_brightness=False, icon="mdi:led-variant-on")
        shown = self._shown()
        self._apply(shown)
        self._state = shown
        self.update_on_changed(self._changed)

    @staticmethod
    def bits(red, green, blue):
        """The three bits of a color. A channel is on when it is at least half of
        the brightest channel. Black gives white (a turn on with no color)."""
        top = max(red, green, blue)
        if top <= 0:
            return 1, 1, 1
        return tuple(1 if value >= 0.5 * top else 0 for value in (red, green, blue))

    def _wanted(self):
        if not self.is_on:
            return (False, False, False)
        return tuple(bool(bit) for bit in self.bits(self.red, self.green, self.blue))

    def _changed(self):
        if self.is_on:
            r, g, b = self.bits(self.red, self.green, self.blue)
            self.red, self.green, self.blue = float(r), float(g), float(b)
        self._hold()
        _send("status %d %d %d" % tuple(int(bit) for bit in self._wanted()))

    def _shown(self):
        return tuple(led_on(name) for name in STATUS_LEDS)

    def _apply(self, shown):
        self.is_on = any(shown)
        if self.is_on:
            self.red, self.green, self.blue = (1.0 if bit else 0.0 for bit in shown)


# ---- switches (EVIOCGSW)

def eviocgsw(length):
    """The ioctl number EVIOCGSW(length) = _IOR('E', 0x1b, length)."""
    return (2 << 30) | (length << 16) | (ord("E") << 8) | 0x1B


def sw_bit(buf, bit):
    return bool(buf[bit // 8] & (1 << (bit % 8)))


def find_switch_node():
    """The event node of the input device gpio-keys that has switches, or None."""
    for path in sorted(glob.glob(os.path.join(SYS_INPUT, "input*"))):
        if _read(os.path.join(path, "name")) != INPUT_NAME:
            continue
        caps = (_read(os.path.join(path, "capabilities", "sw")) or "").split()
        try:
            if not caps or not int(caps[-1], 16):
                continue
        except ValueError:
            continue
        for event in sorted(glob.glob(os.path.join(path, "event*"))):
            return os.path.join(DEV_INPUT, os.path.basename(event))
    return None


def switch_caps():
    """The switch bits of gpio-keys as an int (0 without the device)."""
    for path in sorted(glob.glob(os.path.join(SYS_INPUT, "input*"))):
        if _read(os.path.join(path, "name")) != INPUT_NAME:
            continue
        caps = (_read(os.path.join(path, "capabilities", "sw")) or "").split()
        try:
            return int(caps[-1], 16) if caps else 0
        except ValueError:
            return 0
    return 0


class Switches:
    """Reads the switch bitmap of gpio-keys with EVIOCGSW. One read serves
    both sensors."""

    def __init__(self):
        self.node = None
        self.fdesc = None
        self.buf = None
        self.stamp = 0.0

    def _open(self):
        if self.fdesc is not None:
            return
        self.node = self.node or find_switch_node()
        if self.node is None:
            raise OSError("no input device %s with switches" % INPUT_NAME)
        self.fdesc = os.open(self.node, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0))

    def bit(self, number):
        """The value of switch NUMBER. Raises OSError when it cannot be read, so
        that the sensor keeps its last state."""
        now = time.monotonic()
        if self.buf is None or now - self.stamp >= READ_EVERY:
            self._open()
            try:
                while os.read(self.fdesc, 4096):    # drop the queued events
                    pass
            except OSError:
                pass
            buf = bytearray(SW_BYTES)
            try:
                fcntl.ioctl(self.fdesc, eviocgsw(SW_BYTES), buf, True)
            except OSError:
                os.close(self.fdesc)
                self.fdesc = None
                self.buf = None
                raise
            self.buf, self.stamp = buf, now
        return sw_bit(self.buf, number)


def _hook_value():
    value = HOOK_OFFHOOK_VALUE
    for line in (_read(CONF) or "").splitlines():
        line = line.strip()
        if line.startswith("HOOK_OFFHOOK_VALUE="):
            text = line.split("=", 1)[1].strip().strip("\"'")
            if text in ("0", "1"):
                value = int(text)
    return value


# ---- the diagnostic text

def control_text():
    state = {}
    for line in (_read(LEDS_STATE) or "").splitlines():
        words = line.split()
        if len(words) == 2:
            state[words[0]] = words[1]
    who = state.get("status")
    if who is None:
        return "Unavailable (uc-pxx-leds is not running)"
    text = {"ha": "Home Assistant",
            "boot": "Boot (Home Assistant after the boot is marked good)",
            "locked": "Locked (slot A was changed in this boot)"}.get(who, "Unknown")
    if state.get("red") == "latched":
        text += ", red LED latched"
    return text


# ---- the plugin interface

def entities(server, key_for):
    """The entities of the board. A part that is not there gives no entity."""
    out = []
    shown = [d for d in KEY_LED_DEFS if led_exists(d[2])]
    for object_id, name, led, number in shown:
        out.append(KeyLedLight(server, key_for(object_id), name, object_id, led, number))
    if shown:
        out.append(ButtonEntity(server, key_for("key_leds_release"), "Key LEDs release", "key_leds_release",
                                press=lambda: _send("keys auto"), icon="mdi:led-off"))
    if all(led_exists(name) for name in STATUS_LEDS):
        out.append(StatusLight(server, key_for("status_led")))
        out.append(TextSensorEntity(server, key_for("status_led_control"), "Status LED control",
                                    "status_led_control", get_state=control_text, icon="mdi:led-variant-outline",
                                    entity_category=ENTITY_CATEGORY_DIAGNOSTIC))
    caps = switch_caps()
    if caps:
        switches = Switches()
        if caps & (1 << SW_DOCK):
            hook = _hook_value()
            out.append(BinarySensorEntity(
                server, key_for("handset_off_hook"), "Handset off-hook", "handset_off_hook",
                get_state=lambda: switches.bit(SW_DOCK) == bool(hook), icon="mdi:phone-in-talk"))
        if caps & (1 << SW_CAMERA_LENS_COVER):
            out.append(BinarySensorEntity(
                server, key_for("camera_privacy"), "Camera privacy", "camera_privacy",
                get_state=lambda: switches.bit(SW_CAMERA_LENS_COVER), icon="mdi:camera-lock"))
    return out
