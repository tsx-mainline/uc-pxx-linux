#!/bin/sh
# Host test for the ESPHome plugin of the board (esphome.d/uc-pxx.py). It runs
# the plugin against the tsx_panel code of tsx-linux-common, with a made-up
# /sys/class/input with a file in place of the event node and a replacement
# for the EVIOCGSW ioctl. It checks:
#   - the loader of tsx_panel loads the file, the entity list, the fixed keys
#   - the switches: the ioctl number, the polarity of the hook, the shutter
#   - parts that are missing give no entity
# The LEDs have their own plugin and test (packages/uc-pxx-leds).
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
printf 'class ESPHomeEntity:\n    def __init__(self, server):\n        self.server = server\n' > "$T/stub/linux_voice_assistant/entity.py"
# the plugin folder: a copy with fixed modes
mkdir "$T/pd/good"; cp "$PLUGIN" "$T/pd/good/uc-pxx.py"; chmod 755 "$T/pd/good"; chmod 644 "$T/pd/good/uc-pxx.py"

python3 -I -B - "$SHIM" "$T" <<'PY'
import fcntl, logging, os, stat, sys, time
shim, t = sys.argv[1:3]
sys.path[:0] = [t + "/stub", shim]
os.environ.update(
    TSX_RUN_DIR=t + "/run", UC_PXX_SYS_INPUT=t + "/sysinput",
    UC_PXX_DEV_INPUT=t + "/devinput", UC_PXX_ESPHOME_CONF=t + "/none.conf",
    TSX_PLUGIN_OWNER_UID=str(os.getuid()))

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

mkinput()
mods = plugins.load(t + "/pd/good")
check("the plugin loads in the loader of tsx_panel", [os.path.basename(m.__file__) for m in mods], ["uc-pxx.py"])
mod = mods[0]
srv = object()

def build():
    return list(mod.entities(srv, Keys()))

ents = build()
by = {e.object_id: e for e in ents}
check("the object ids", sorted(by), ["camera_privacy", "handset_off_hook"])
check("the names", sorted(e.name for e in ents), ["Camera privacy", "Handset off-hook"])
check("the keys are the fixed keys of tsx_panel", all(e.key == stable_key(e.object_id) for e in ents), True)
check("the keys are different and at least 0x10000", len({e.key for e in ents}) == len(ents) and min(e.key for e in ents) >= 0x10000, True)
check("no LED entity: the LEDs have their own plugin", [o for o in by if "led" in o], [])

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
mkinput(None)
check("no gpio-keys: no entity", [e.object_id for e in mod.entities(srv, Keys())], [])
mkinput("20")
check("gpio-keys with the hook bit only (bit 9 clear): no camera sensor",
      sorted(e.object_id for e in mod.entities(srv, Keys())), ["handset_off_hook"])
check("the plugin file is not writable by the group", stat.S_IMODE(os.stat(t + "/pd/good/uc-pxx.py").st_mode) & 0o022, 0)

print("%d failed" % fails)
sys.exit(1 if fails else 0)
PY
rc=$?
exit $rc
