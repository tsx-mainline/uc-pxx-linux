# SPDX-License-Identifier: GPL-2.0-or-later
"""uc-pxx-leds.py: the ESPHome plugin of the package uc-pxx-leds.

It follows the plugin interface of tsx-linux-common (docs/esphome.md
"Plugins") and adds these entities to the ESPHome device:

  Teams LED, Headset LED, Speaker LED, Mic mute LED   lights (on/off)
  Status LED                                          light (RGB, 7 colors, effects)
  Status LED control                                  text sensor (diagnostic)

The object ids are fixed: teams_led, headset_led, speaker_led, mic_mute_led,
status_led and status_led_control. They keep the keys of the entities.

The plugin may run as user kiosk (VOICE=on). That user cannot write an LED. So
every change goes as one line to the control socket of the root daemon
uc-pxx-leds. The plugin reads the state from the state file of the daemon and
never touches /sys/class/leds, except to see which LEDs exist. The daemon
writes the state file before it answers a command. So after a refused command
(the status LED during the boot) the next poll shows the real state again.

A light of Home Assistant is a normal control, not a configuration entity: the
plugin sets entity_category to none in the entity list. The class
LEDLightEntity of linux-voice-assistant sets it to config.

The rules for the LEDs are in docs/leds.md of the uc-pxx-linux repository.

Environment overrides for tests: UC_PXX_LEDS (the LED class folder),
UC_PXX_LEDS_SOCK, UC_PXX_LEDS_STATE and TSX_RUN_DIR.
"""

import logging
import os
import socket
import time

from linux_voice_assistant.entity import LEDLightEntity
from tsx_panel.entities import ENTITY_CATEGORY_DIAGNOSTIC, TextSensorEntity

_LOGGER = logging.getLogger("uc_pxx.leds")

RUN = os.environ.get("TSX_RUN_DIR", "/run/tsx")
LEDS = os.environ.get("UC_PXX_LEDS", "/sys/class/leds")
SOCK = os.environ.get("UC_PXX_LEDS_SOCK", os.path.join(RUN, "uc-pxx-leds.sock"))
STATE = os.environ.get("UC_PXX_LEDS_STATE", os.path.join(RUN, "uc-pxx-leds.state"))

ENTITY_CATEGORY_NONE = 0
CACHE_S = 0.2                  # the state file is read at most this often
SEND_TIMEOUT = 0.5             # seconds that a command may take

# (object id, name, indicator name of the daemon, LED class device)
INDICATOR_DEFS = (
    ("teams_led", "Teams LED", "teams", "teams_white"),
    ("headset_led", "Headset LED", "headset", "mute_headset"),
    ("speaker_led", "Speaker LED", "speaker", "mute_speaker"),
    ("mic_mute_led", "Mic mute LED", "mic", "mute_red"),
)
STATUS_LEDS = ("red", "green", "blue")
COLORS = {"off": (0, 0, 0), "red": (1, 0, 0), "green": (0, 1, 0), "blue": (0, 0, 1),
          "yellow": (1, 1, 0), "cyan": (0, 1, 1), "magenta": (1, 0, 1), "white": (1, 1, 1)}
# effect name of Home Assistant -> words of the "status" command after the color
EFFECTS = {"Solid": "solid", "Blink": "blink slow", "Fast blink": "blink fast", "Heartbeat": "heartbeat"}
SHOWN_EFFECT = {"solid": "Solid", "blink slow": "Blink", "blink fast": "Fast blink", "heartbeat": "Heartbeat"}

_cache = {"stamp": -1e9, "data": None}


def state():
    """The state file of the daemon as a dict (key -> list of words), or None
    when the daemon has not written it."""
    now = time.monotonic()
    if now - _cache["stamp"] >= CACHE_S:
        _cache["stamp"] = now
        try:
            with open(STATE, "r", encoding="ascii", errors="replace") as fobj:
                text = fobj.read()
        except OSError:
            text = None
        data = None
        if text is not None:
            data = {}
            for line in text.splitlines():
                words = line.split()
                if len(words) >= 2:
                    data[words[0]] = words[1:]
        _cache["data"] = data
    return _cache["data"]


def send(line):
    """One command line to the daemon. Return True when it answered ok."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(SEND_TIMEOUT)
    try:
        sock.connect(SOCK)
        sock.sendall((line + "\n").encode("ascii"))
        answer = b""
        while True:
            chunk = sock.recv(256)
            if not chunk:
                break
            answer += chunk
    except OSError as err:
        _LOGGER.warning("uc-pxx-leds does not answer (%s): %s", SOCK, err)
        return False
    finally:
        sock.close()
    _cache["stamp"] = -1e9              # read the state file again
    if answer.strip() != b"ok":
        _LOGGER.info("uc-pxx-leds refused %r: %s", line, answer.decode("ascii", "replace").strip())
        return False
    return True


def led_exists(name):
    return os.path.isdir(os.path.join(LEDS, name))


class _Light(LEDLightEntity):
    """A light whose state comes from the state file of the daemon. The color
    of Home Assistant has the brightest channel at 1.0 and the brightness
    alone sets the level, so the entity reports color_brightness 1.0, as
    PanelLight of the device does."""

    def handle_message(self, msg):
        for out in LEDLightEntity.handle_message(self, msg):
            # LEDLightEntity lists its entity as a config entity. A LED is a control.
            if type(out).__name__ == "ListEntitiesLightResponse":
                out.entity_category = ENTITY_CATEGORY_NONE
            yield out

    def _state_response(self):
        response = LEDLightEntity._state_response(self)
        response.color_brightness = 1.0
        return response

    def poll(self):
        """The state response when the state file shows something new."""
        shown = self._shown()
        if shown is None or shown == self._state:
            return None
        self._apply(shown)
        self._state = shown
        return self._state_response()


class IndicatorLight(_Light):
    """A key indicator as an on/off light. A blinking indicator shows as on."""

    def __init__(self, server, key, name, object_id, indicator):
        LEDLightEntity.__init__(self, server, key, name, object_id, supports_rgb=False,
                                supports_brightness=False, icon="mdi:led-on")
        self.indicator = indicator
        self._state = None
        shown = self._shown()
        if shown is not None:
            self._apply(shown)
            self._state = shown
        self.update_on_changed(self._changed)

    def _shown(self):
        data = state()
        words = (data or {}).get(self.indicator)
        return None if not words else (words[0] != "off",)

    def _apply(self, shown):
        self.is_on = shown[0]

    def _changed(self):
        send("ind %s %s" % (self.indicator, "on" if self.is_on else "off"))
        self._state = (self.is_on,)


class StatusLight(_Light):
    """The RGB status LED: 7 colors and off, with the effects Solid, Blink,
    Fast blink and Heartbeat."""

    def __init__(self, server, key):
        LEDLightEntity.__init__(self, server, key, "Status LED", "status_led", supports_rgb=True,
                                supports_brightness=False, effects=list(EFFECTS),
                                icon="mdi:led-variant-on")
        self._state = None
        shown = self._shown()
        if shown is not None:
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

    @staticmethod
    def color_name(bits):
        for name, val in COLORS.items():
            if val == tuple(bits):
                return name
        return "off"

    def _shown(self):
        words = (state() or {}).get("shown")
        if not words or words[0] not in COLORS:
            return None
        return (words[0], SHOWN_EFFECT.get(" ".join(words[1:]), "Solid"))

    def _apply(self, shown):
        color, effect = shown
        self.is_on = color != "off"
        if self.is_on:
            self.red, self.green, self.blue = (float(b) for b in COLORS[color])
            self.effect = effect

    def _changed(self):
        if not self.is_on:
            send("status off")
            self._state = ("off", self.effect)
            return
        bits = self.bits(self.red, self.green, self.blue)
        color = self.color_name(bits)
        self.red, self.green, self.blue = (float(b) for b in bits)
        effect = self.effect if self.effect in EFFECTS else "Solid"
        send("status %s %s" % (color, EFFECTS[effect]))
        self._state = (color, effect)


def control_text():
    data = state()
    if data is None:
        return "Unavailable (uc-pxx-leds is not running)"
    boot = (data.get("boot") or ["?"])[0]
    text = {"ok": "Free",
            "wait": "Boot (the boot is not marked good yet, blue heartbeat)",
            "locked": "Locked (slot A was changed in this boot, blue heartbeat)"}.get(boot, "Unknown")
    if (data.get("red") or [""])[0] == "latched":
        text += ", red LED latched"
    return text


# ---- the plugin interface

def entities(server, key_for):
    """The entities of the package. A part that is not there gives no entity."""
    out = []
    for object_id, name, indicator, led in INDICATOR_DEFS:
        if led_exists(led):
            out.append(IndicatorLight(server, key_for(object_id), name, object_id, indicator))
    if all(led_exists(name) for name in STATUS_LEDS):
        out.append(StatusLight(server, key_for("status_led")))
        out.append(TextSensorEntity(server, key_for("status_led_control"), "Status LED control",
                                    "status_led_control", get_state=control_text,
                                    icon="mdi:led-variant-outline",
                                    entity_category=ENTITY_CATEGORY_DIAGNOSTIC))
    return out
