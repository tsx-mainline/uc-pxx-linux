# SPDX-License-Identifier: GPL-2.0-or-later
"""uc-pxx.py: the ESPHome plugin of the uc-pxx board (UC-P10 and UC-P8).

It follows the plugin interface of tsx-linux-common (docs/esphome.md
"Plugins") and adds these entities to the ESPHome device:

  Handset off-hook                                    binary sensor
  Camera privacy                                      binary sensor

The LEDs (the four key indicators and the RGB status LED) are not here. They
have their own package, uc-pxx-leds, with its own plugin
(esphome.d/uc-pxx-leds.py, docs/leds.md).

The switches are read with the ioctl EVIOCGSW, once or twice a second. tsx-idled
opens every input device and grabs it while the screen is blank, so a reader of
events would miss changes. The ioctl works with a grabbed device.

Environment overrides for tests: UC_PXX_SYS_INPUT, UC_PXX_DEV_INPUT,
UC_PXX_ESPHOME_CONF.
"""

import fcntl
import glob
import os
import time

from tsx_panel.entities import BinarySensorEntity

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


def _read(path):
    try:
        with open(path, "r", encoding="utf-8") as fobj:
            return fobj.read().strip()
    except OSError:
        return None


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


# ---- the plugin interface

def entities(server, key_for):
    """The entities of the board. A part that is not there gives no entity."""
    out = []
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
