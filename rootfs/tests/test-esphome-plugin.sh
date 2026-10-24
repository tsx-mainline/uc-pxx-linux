#!/bin/sh
# Host test for the ESPHome plugin of the board (esphome.d/uc-pxx.py). It runs
# the plugin against the tsx_panel code of tsx-linux-common, with a made-up
# /sys/class/leds, a made-up /sys/class/input with a file in place of the
# event node, a replacement for the EVIOCGSW ioctl and a real FIFO in place of
# the one of uc-pxx-leds. It checks:
#   - the loader of tsx_panel loads the file, the entity list, the fixed keys
#   - the four key LED lights, the release button, the commands in the FIFO
#   - the status LED light: colors, the red LED, the held state
#   - the switches: the ioctl number, the polarity of the hook, the shutter
#   - parts that are missing give no entity
# TSX_COMMON names the checkout of tsx-linux-common (default: ../tsx-linux-common
# next to this repository). Without it the test prints SKIPPED. Small stand-ins
# replace aioesphomeapi, protobuf and linux_voice_assistant. The test writes no
# file into the checkout of common.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PLUGIN=$HERE/overlay/usr/local/share/tsx/esphome.d/uc-pxx.py
COMMON=${TSX_COMMON:-$HERE/../../tsx-linux-common}
SHIM=$COMMON/ha/voice/shim
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: no python3"; exit 0; }
[ -f "$SHIM/tsx_panel/plugins.py" ] || { echo "SKIPPED: no tsx-linux-common (set TSX_COMMON)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$T/stub/aioesphomeapi" "$T/stub/google/protobuf" "$T/stub/linux_voice_assistant" "$T/pd"
: > "$T/stub/aioesphomeapi/__init__.py"
cat > "$T/stub/aioesphomeapi/api_pb2.py" <<'PY'
_classes = {}
def __getattr__(name):
    if name.startswith("__"):
        raise AttributeError(name)
    if name not in _classes:
        _classes[name] = type(name, (), {"__init__": lambda self, **kw: self.__dict__.update(kw)})
    return _classes[name]
PY
: > "$T/stub/google/__init__.py"; : > "$T/stub/google/protobuf/__init__.py"
echo "class Message: pass" > "$T/stub/google/protobuf/message.py"
: > "$T/stub/linux_voice_assistant/__init__.py"
# LEDLightEntity as in linux-voice-assistant 1.1.15 (entity.py), reduced to what the plugin uses
cat > "$T/stub/linux_voice_assistant/entity.py" <<'PY'
from aioesphomeapi import api_pb2 as pb

class ESPHomeEntity:
    def __init__(self, server):
        self.server = server

class LEDLightEntity(ESPHomeEntity):
    def __init__(self, server, key, name, object_id, effects=None, supports_rgb=True,
                 supports_brightness=True, on_changed=None, icon="mdi:led-strip-variant"):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id, self.icon = key, name, object_id, icon
        self._on_changed = on_changed
        self.effects_list = list(effects) if effects else []
        self._supports_rgb, self._supports_brightness = supports_rgb, supports_brightness
        self.is_on, self.brightness = False, 0.66
        self.red, self.green, self.blue = 0.094, 0.733, 0.949
        self.effect = ""

    def update_on_changed(self, on_changed):
        self._on_changed = on_changed

    def _color_mode(self):
        return "rgb" if self._supports_rgb else "brightness" if self._supports_brightness else "onoff"

    def handle_message(self, msg):
        if isinstance(msg, pb.LightCommandRequest) and msg.key == self.key:
            changed = False
            if getattr(msg, "has_state", False):
                self.is_on, changed = bool(msg.state), True
            if getattr(msg, "has_brightness", False) and self._supports_brightness:
                self.brightness, changed = float(msg.brightness), True
            if getattr(msg, "has_rgb", False) and self._supports_rgb:
                self.red, self.green, self.blue, changed = float(msg.red), float(msg.green), float(msg.blue), True
            if changed and self._on_changed is not None:
                self._on_changed()
            yield self._state_response()
        elif isinstance(msg, pb.ListEntitiesRequest):
            yield pb.ListEntitiesLightResponse(object_id=self.object_id, key=self.key, name=self.name,
                                               supported_color_modes=[self._color_mode()])
        elif isinstance(msg, pb.SubscribeHomeAssistantStatesRequest):
            yield self._state_response()

    def _state_response(self):
        return pb.LightStateResponse(key=self.key, state=self.is_on, brightness=self.brightness,
                                     color_brightness=self.brightness, red=self.red, green=self.green,
                                     blue=self.blue, effect=self.effect)
PY

# the plugin folder: a copy with fixed modes
mkdir "$T/pd/good"; cp "$PLUGIN" "$T/pd/good/uc-pxx.py"; chmod 755 "$T/pd/good"; chmod 644 "$T/pd/good/uc-pxx.py"

python3 -I -B - "$SHIM" "$T" <<'PY'
import fcntl, logging, os, stat, sys, time
shim, t = sys.argv[1:3]
sys.path[:0] = [t + "/stub", shim]
os.environ.update(
    TSX_RUN_DIR=t + "/run", UC_PXX_LEDS=t + "/leds", UC_PXX_LEDS_FIFO=t + "/run/uc-pxx-leds",
    UC_PXX_LEDS_STATE=t + "/run/uc-pxx-leds.state", UC_PXX_SYS_INPUT=t + "/sysinput",
    UC_PXX_DEV_INPUT=t + "/devinput", UC_PXX_ESPHOME_CONF=t + "/none.conf",
    TSX_PLUGIN_OWNER_UID=str(os.getuid()))
os.makedirs(t + "/run")

from aioesphomeapi import api_pb2 as pb
from tsx_panel import plugins
from tsx_panel.keys import Keys, stable_key

fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print("ok  ", name)
    else:
        print("FAIL", name, "got", repr(got), "want", repr(want)); fails += 1

def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fobj:
        fobj.write(text)

def mkleds(missing=()):
    import shutil
    shutil.rmtree(t + "/leds", ignore_errors=True)
    for name in ("teams_white", "mute_headset", "mute_speaker", "mute_red", "red", "green", "blue"):
        if name in missing:
            continue
        put("%s/leds/%s/brightness" % (t, name), "0\n")
        put("%s/leds/%s/trigger" % (t, name), "[none] heartbeat default-on\n")

def setled(name, val, trigger=None):
    put("%s/leds/%s/brightness" % (t, name), "%d\n" % val)
    if trigger:
        put("%s/leds/%s/trigger" % (t, name), "none [%s] default-on\n" % trigger)

def mkinput(sw="a20"):
    import shutil
    shutil.rmtree(t + "/sysinput", ignore_errors=True); shutil.rmtree(t + "/devinput", ignore_errors=True)
    os.makedirs(t + "/devinput")
    if sw is None:
        return
    put(t + "/sysinput/input0/name", "mXT1066\n"); put(t + "/sysinput/input0/capabilities/sw", "0\n")
    os.makedirs(t + "/sysinput/input0/event0")
    put(t + "/sysinput/input4/name", "gpio-keys\n"); put(t + "/sysinput/input4/capabilities/sw", sw + "\n")
    os.makedirs(t + "/sysinput/input4/event4")
    open(t + "/devinput/event4", "w").close()

# the switch bits that the fake ioctl returns, and the calls that it saw
SW = {"bits": 0, "calls": []}
def fake_ioctl(fdesc, request, buf, mutate=True):
    SW["calls"].append(request)
    for i in range(len(buf)):
        buf[i] = (SW["bits"] >> (8 * i)) & 0xFF
    return 0
fcntl.ioctl = fake_ioctl

# the FIFO of uc-pxx-leds, with a reader, as the helper would hold it
os.mkfifo(t + "/run/uc-pxx-leds")
reader = os.open(t + "/run/uc-pxx-leds", os.O_RDONLY | os.O_NONBLOCK)
def sent():
    try:
        data = os.read(reader, 65536).decode()
    except BlockingIOError:
        data = ""
    return data.splitlines()

mkleds(); mkinput()
mods = plugins.load(t + "/pd/good")
check("the plugin loads in the loader of tsx_panel", [os.path.basename(m.__file__) for m in mods], ["uc-pxx.py"])
mod = mods[0]
srv = object()

def build():
    return list(mod.entities(srv, Keys()))

ents = build()
by = {e.object_id: e for e in ents}
check("the object ids", sorted(by), sorted([
    "teams_led", "headset_led", "speaker_led", "mic_mute_led", "key_leds_release", "status_led",
    "status_led_control", "handset_off_hook", "camera_privacy"]))
check("the names", sorted(e.name for e in ents), sorted([
    "Teams LED", "Headset LED", "Speaker LED", "Mic mute LED", "Key LEDs release", "Status LED",
    "Status LED control", "Handset off-hook", "Camera privacy"]))
check("the keys are the fixed keys of tsx_panel", all(e.key == stable_key(e.object_id) for e in ents), True)
check("the keys are different and at least 0x10000", len({e.key for e in ents}) == len(ents) and min(e.key for e in ents) >= 0x10000, True)
check("no object id of the device is reused", [o for o in by if o.startswith("key_") and o != "key_leds_release"], [])
check("the loader takes all of them", len(build()), 9)

# ---- the key LEDs
teams = by["teams_led"]
check("a key LED light is an on/off light", teams._color_mode(), "onoff")
check("it shows the LED: dark, no message", (teams.is_on, plugins.poll([teams])), (False, []))
list_msgs = list(teams.handle_message(pb.ListEntitiesRequest()))
check("the entity list", (list_msgs[0].object_id, list_msgs[0].name), ("teams_led", "Teams LED"))
setled("teams_white", 1)
check("the poll follows the LED", (len(plugins.poll([teams])), teams.is_on), (1, True))
check("an unchanged LED sends nothing", plugins.poll([teams]), [])
out = list(teams.handle_message(pb.LightCommandRequest(key=teams.key, has_state=True, state=False)))
check("off: the answer says off", out[0].state, False)
check("off: one line in the FIFO", sent(), ["key 1 off"])
check("held: the poll sends nothing while the hold runs", teams.poll(), None)
teams._hold_until = 0
resp = teams.poll()
check("the helper refused (the LED is still on): the poll sends the real state", (resp is not None, resp.state if resp else None), (True, True))
setled("teams_white", 0)
list(teams.handle_message(pb.LightCommandRequest(key=teams.key, has_state=True, state=True)))
check("on: key 1 on", sent(), ["key 1 on"])
teams._hold_until = 0
resp = teams.poll()
check("on, the LED stays dark (the level of Key LEDs is 0): the state goes back to off", (resp is not None, resp.state if resp else None), (True, False))
for oid, line in (("headset_led", "key 2"), ("speaker_led", "key 3"), ("mic_mute_led", "key 4")):
    ent = by[oid]
    list(ent.handle_message(pb.LightCommandRequest(key=ent.key, has_state=True, state=False)))
    check(oid + " sends " + line + " off", sent(), [line + " off"])
rel = by["key_leds_release"]
list(rel.handle_message(pb.ButtonCommandRequest(key=rel.key)))
check("the release button: keys auto", sent(), ["keys auto"])
check("the other keys do not change the lights", by["headset_led"].key != by["teams_led"].key, True)

# ---- the status LED
st = by["status_led"]
check("the status LED is an RGB light", st._color_mode(), "rgb")
check("dark at the start", (st.is_on, plugins.poll([st])), (False, []))
def cmd(**kw):
    out = list(st.handle_message(pb.LightCommandRequest(key=st.key, has_state=True, has_rgb=True, **kw)))
    st._hold_until = 0
    return out[0]
r = cmd(state=True, red=1.0, green=0.65, blue=0.0)
check("orange gives yellow (red and green)", sent(), ["status 1 1 0"])
check("the answer has the quantized color", (r.red, r.green, r.blue), (1.0, 1.0, 0.0))
cmd(state=True, red=0.0, green=0.0, blue=1.0); check("blue", sent(), ["status 0 0 1"])
cmd(state=True, red=1.0, green=1.0, blue=1.0); check("white", sent(), ["status 1 1 1"])
cmd(state=True, red=1.0, green=0.0, blue=1.0); check("magenta", sent(), ["status 1 0 1"])
cmd(state=True, red=0.0, green=1.0, blue=1.0); check("cyan", sent(), ["status 0 1 1"])
cmd(state=True, red=0.0, green=1.0, blue=0.0); check("green", sent(), ["status 0 1 0"])
cmd(state=True, red=1.0, green=0.0, blue=0.0); check("red", sent(), ["status 1 0 0"])
cmd(state=True, red=0.0, green=0.0, blue=0.0); check("black on gives white", sent(), ["status 1 1 1"])
cmd(state=True, red=0.9, green=0.3, blue=0.2); check("a weak channel counts as off", sent(), ["status 1 0 0"])
list(st.handle_message(pb.LightCommandRequest(key=st.key, has_state=True, state=False)))
check("off", sent(), ["status 0 0 0"])
# the hardware: the shown state follows the LEDs, also the blue heartbeat of the boot
st._hold_until = 0; st.poll()
setled("green", 1)
r = st.poll(); check("green LED on: the light says green", (r.state, r.red, r.green, r.blue), (True, 0.0, 1.0, 0.0))
setled("green", 0); st.poll()
setled("blue", 0, trigger="heartbeat")
r = st.poll(); check("the blue heartbeat counts as blue on, whatever the brightness", (r.state, r.blue), (True, 1.0))
setled("blue", 1, trigger="heartbeat"); check("the same heartbeat, brightness 1: no new message", plugins.poll([st]), [])
setled("blue", 0); put(t + "/leds/blue/trigger", "[none] heartbeat\n"); st.poll()
setled("red", 1); setled("blue", 1)
r = st.poll(); check("red and blue: magenta", (r.red, r.green, r.blue), (1.0, 0.0, 1.0))
# a refused command (red latched): Home Assistant asked for blue only, the LED shows red and blue
setled("red", 1); setled("blue", 0)
st._hold_until = 0; st.poll()
list(st.handle_message(pb.LightCommandRequest(key=st.key, has_state=True, has_rgb=True, state=True, red=0.0, green=0.0, blue=1.0)))
sent(); st._hold_until = 0
setled("blue", 1)
r = st.poll(); check("red stays lit: the poll shows the red LED again", (r.red, r.green, r.blue), (1.0, 0.0, 1.0))
setled("red", 0); setled("blue", 0)

# ---- the diagnostic text
txt = by["status_led_control"]
check("the control text is a diagnostic text sensor", txt.entity_category, 2)
check("no state file: the helper is not running", txt._get_state(), "Unavailable (uc-pxx-leds is not running)")
put(t + "/run/uc-pxx-leds.state", "status boot\nred free\n")
check("boot", txt._get_state(), "Boot (Home Assistant after the boot is marked good)")
put(t + "/run/uc-pxx-leds.state", "status ha\nred free\n"); check("ha", txt._get_state(), "Home Assistant")
put(t + "/run/uc-pxx-leds.state", "status ha\nred latched\n"); check("red latched", txt._get_state(), "Home Assistant, red LED latched")
put(t + "/run/uc-pxx-leds.state", "status locked\nred free\n"); check("locked", txt._get_state(), "Locked (slot A was changed in this boot)")

# ---- the switches
check("EVIOCGSW(8)", hex(mod.eviocgsw(8)), "0x8008451b")
hook, cam = by["handset_off_hook"], by["camera_privacy"]
check("the sensors are binary sensors", (type(hook).__name__, type(cam).__name__), ("BinarySensorEntity", "BinarySensorEntity"))
SW["bits"] = 1 << 5                      # SW_DOCK = 1: the handset is lifted (the UC-P10, 2026-10-24), shutter open
SW["calls"].clear()
r = hook.poll()
check("SW_DOCK = 1: off-hook", r.state, True)
check("the ioctl was EVIOCGSW(8)", SW["calls"], [0x8008451b])
check("the shutter is open", cam.poll().state, False)
check("one read serves both sensors", len(SW["calls"]), 1)
mod.READ_EVERY = 0
SW["bits"] = 0                           # SW_DOCK = 0: the handset is on the cradle
check("SW_DOCK = 0: not off-hook", hook.poll().state, False)
SW["bits"] = 1 << 9
check("SW_CAMERA_LENS_COVER = 1: privacy on", cam.poll().state, True)
check("and the hook is on the cradle (SW_DOCK = 0)", hook.poll().state, False)
SW["bits"] = (1 << 5) | (1 << 9) | (1 << 11)   # the PIR bit does not matter
check("the PIR bit is ignored", (hook.poll().state, cam.poll().state), (True, True))
# a failing ioctl keeps the last state
def bad_ioctl(*a):
    raise OSError(25, "not a tty")
fcntl.ioctl = bad_ioctl
check("a failing ioctl: the state stays", (hook.poll().state, cam.poll().state), (True, True))
fcntl.ioctl = fake_ioctl
SW["bits"] = 0
check("the next read works again", hook.poll().state, False)
# the plugin poll of tsx_panel sends a message only on a change
SW["bits"] = 1 << 5
check("plugins.poll: a change goes out", len(plugins.poll([hook])), 1)
check("plugins.poll: no change, no message", plugins.poll([hook]), [])
# the polarity can be changed
put(t + "/none.conf", "HOOK_OFFHOOK_VALUE=0\n")
mkinput(); ents2 = list(mod.entities(srv, Keys()))
h2 = [e for e in ents2 if e.object_id == "handset_off_hook"][0]
SW["bits"] = 0
check("HOOK_OFFHOOK_VALUE=0: SW_DOCK = 0 is off-hook", h2.poll().state, True)
os.unlink(t + "/none.conf")

# ---- parts that are missing
mkleds(missing=("teams_white", "mute_headset", "mute_speaker", "mute_red")); mkinput("a20")
check("no key LEDs: no key LED light and no release button",
      sorted(e.object_id for e in mod.entities(srv, Keys())),
      ["camera_privacy", "handset_off_hook", "status_led", "status_led_control"])
mkleds(missing=("blue")); mkinput(None)
check("no blue LED and no gpio-keys: only the key LEDs",
      sorted(e.object_id for e in mod.entities(srv, Keys())),
      ["headset_led", "key_leds_release", "mic_mute_led", "speaker_led", "teams_led"])
mkleds(); mkinput("20")
check("gpio-keys with the hook bit only (bit 9 clear): no camera sensor",
      sorted(e.object_id for e in mod.entities(srv, Keys()) if "camera" in e.object_id or "hook" in e.object_id),
      ["handset_off_hook"])
mkleds(); mkinput("a20")
os.close(reader)
check("no reader of the FIFO: a command is dropped with a log line, no error",
      (list(teams.handle_message(pb.LightCommandRequest(key=teams.key, has_state=True, state=False)))[0].state,), (False,))
check("the plugin file is not writable by the group", stat.S_IMODE(os.stat(t + "/pd/good/uc-pxx.py").st_mode) & 0o022, 0)

print("%d failed" % fails)
sys.exit(1 if fails else 0)
PY
rc=$?
exit $rc
