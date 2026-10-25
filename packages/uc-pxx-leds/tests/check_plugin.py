# Checks of the ESPHome plugin uc-pxx-leds.py (called by test-plugin.sh). The
# stand-ins for aioesphomeapi, protobuf and linux_voice_assistant are in the
# folder t/stub. The plugin is loaded by the loader of tsx_panel.
import os
import socket
import sys
import threading

shim, t, prog = sys.argv[1:4]
sys.path[:0] = [t + "/stub", shim]
os.environ.update(TSX_RUN_DIR=t + "/run", UC_PXX_LEDS=t + "/leds", UC_PXX_LEDS_SOCK=t + "/run/sock",
                  UC_PXX_LEDS_STATE=t + "/run/state", TSX_PLUGIN_OWNER_UID=str(os.getuid()))
os.makedirs(t + "/run", exist_ok=True)

from aioesphomeapi import api_pb2 as pb  # noqa: E402
from tsx_panel import plugins  # noqa: E402
from tsx_panel.keys import Keys, stable_key  # noqa: E402

fails = 0


def check(name, got, want):
    global fails
    if got == want:
        print("ok  ", name)
    else:
        print("FAIL", name, "got", repr(got), "want", repr(want))
        fails += 1


def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fobj:
        fobj.write(text)


def mkleds(missing=()):
    import shutil
    shutil.rmtree(t + "/leds", ignore_errors=True)
    for name in ("teams_white", "mute_headset", "mute_speaker", "mute_red", "red", "green", "blue"):
        if name not in missing:
            put("%s/leds/%s/brightness" % (t, name), "0\n")


def setstate(boot="ok", red="free", teams="off", headset="off", speaker="off", mic="off", status="auto", shown="green solid"):
    put(t + "/run/state", "boot %s\nred %s\nteams %s\nheadset %s\nspeaker %s\nmic %s\nstatus %s\nshown %s\npersist no\n"
        % (boot, red, teams, headset, speaker, mic, status, shown))


class Daemon(threading.Thread):
    """A stand-in for the daemon: it records each line and answers."""

    def __init__(self):
        threading.Thread.__init__(self, daemon=True)
        self.lines = []
        self.answer = b"ok\n"
        self.sock = socket.socket(socket.AF_UNIX)
        if os.path.exists(t + "/run/sock"):
            os.unlink(t + "/run/sock")
        self.sock.bind(t + "/run/sock")
        self.sock.listen(4)
        self.running = True

    def run(self):
        while self.running:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(256)
                if not chunk:
                    break
                data += chunk
            self.lines.append(data.decode().strip())
            conn.sendall(self.answer)
            conn.close()

    def take(self):
        out, self.lines = self.lines, []
        return out

    def stop(self):
        self.running = False
        self.sock.close()


mkleds()
setstate()
mods = plugins.load(t + "/pd/good")
check("the plugin loads in the loader of tsx_panel", [os.path.basename(m.__file__) for m in mods], ["uc-pxx-leds.py"])
mod = mods[0]
mod.CACHE_S = 0           # read the state file at each poll
srv = object()
daemon = Daemon()
daemon.start()


def build():
    return list(mod.entities(srv, Keys()))


ents = build()
by = {e.object_id: e for e in ents}
want_ids = ["headset_led", "mic_mute_led", "speaker_led", "status_led", "status_led_control", "teams_led"]
check("the object ids are the old ones", sorted(by), want_ids)
check("no key_leds_release button", "key_leds_release" in by, False)
check("the names", sorted(e.name for e in ents), sorted(
    ["Teams LED", "Headset LED", "Speaker LED", "Mic mute LED", "Status LED", "Status LED control"]))
check("the keys are the fixed keys of tsx_panel", all(e.key == stable_key(e.object_id) for e in ents), True)
check("the keys are different and at least 0x10000", len({e.key for e in ents}) == len(ents) and min(e.key for e in ents) >= 0x10000, True)
check("the keys of the old plugin stay (FNV-1a of tsx:<object id>)",
      {o: by[o].key for o in by}, {o: stable_key(o) for o in want_ids})

# ---- the entity category
for oid in ("teams_led", "headset_led", "speaker_led", "mic_mute_led", "status_led"):
    msgs = list(by[oid].handle_message(pb.ListEntitiesRequest()))
    check("%s: listed with the category none (the class sets config)" % oid, (len(msgs), msgs[0].entity_category), (1, 0))
check("the text sensor is a diagnostic entity", by["status_led_control"].entity_category, 2)
msgs = list(by["teams_led"].handle_message(pb.SubscribeHomeAssistantStatesRequest()))
check("a state message is not changed", (len(msgs), hasattr(msgs[0], "entity_category")), (1, False))

# ---- the indicators
teams = by["teams_led"]
check("an indicator is an on/off light", teams._color_mode(), "onoff")
check("dark at the start, no message", (teams.is_on, plugins.poll([teams])), (False, []))
setstate(teams="on")
r = plugins.poll([teams])
check("the state file says on: the light follows", (len(r), teams.is_on), (1, True))
check("an unchanged state sends nothing", plugins.poll([teams]), [])
setstate(teams="blink fast")
check("a blinking indicator is on, and nothing new goes out", (teams.is_on, plugins.poll([teams])), (True, []))
out = list(teams.handle_message(pb.LightCommandRequest(key=teams.key, has_state=True, state=False)))
check("off: the answer says off", out[0].state, False)
check("off: one command", daemon.take(), ["ind teams off"])
check("the answer has color_brightness 1.0", out[0].color_brightness, 1.0)
check("the daemon has not changed the file yet (refused): the poll sends the real state",
      [r.state for r in plugins.poll([teams])], [True])
setstate(teams="off")
list(teams.handle_message(pb.LightCommandRequest(key=teams.key, has_state=True, state=True)))
check("on", daemon.take(), ["ind teams on"])
setstate(teams="on")
check("and the state file agrees: no message", plugins.poll([teams]), [])
for oid, who in (("headset_led", "headset"), ("speaker_led", "speaker"), ("mic_mute_led", "mic")):
    ent = by[oid]
    list(ent.handle_message(pb.LightCommandRequest(key=ent.key, has_state=True, state=True)))
    check(oid + " on", daemon.take(), ["ind %s on" % who])
    setstate(**{who: "on"})
    check(oid + " follows its own line only", (ent.poll() is None, by["teams_led"].is_on), (True, True))
setstate()
for oid in ("headset_led", "speaker_led", "mic_mute_led", "teams_led"):
    plugins.poll([by[oid]])
check("all four off again", [by[o].is_on for o in ("teams_led", "headset_led", "speaker_led", "mic_mute_led")], [False] * 4)

# ---- the status LED
st = by["status_led"]
check("the status LED is an RGB light", st._color_mode(), "rgb")
check("it has the effects Solid, Blink, Fast blink and Heartbeat", st.effects_list, ["Solid", "Blink", "Fast blink", "Heartbeat"])
check("it shows green solid", (st.is_on, st.red, st.green, st.blue, st.effect), (True, 0.0, 1.0, 0.0, "Solid"))


def cmd(**kw):
    out = list(st.handle_message(pb.LightCommandRequest(key=st.key, has_state=True, has_rgb=True, **kw)))
    return out[0]


r = cmd(state=True, red=1.0, green=0.65, blue=0.0)
check("orange gives yellow", daemon.take(), ["status yellow solid"])
check("the answer has the quantized color", (r.red, r.green, r.blue), (1.0, 1.0, 0.0))
for rgb, name in (((0, 0, 1), "blue"), ((1, 1, 1), "white"), ((1, 0, 1), "magenta"), ((0, 1, 1), "cyan"), ((0, 1, 0), "green"), ((1, 0, 0), "red")):
    cmd(state=True, red=float(rgb[0]), green=float(rgb[1]), blue=float(rgb[2]))
    check(name, daemon.take(), ["status %s solid" % name])
cmd(state=True, red=0.0, green=0.0, blue=0.0); check("black on gives white", daemon.take(), ["status white solid"])
cmd(state=True, red=0.9, green=0.3, blue=0.2); check("a weak channel counts as off", daemon.take(), ["status red solid"])
list(st.handle_message(pb.LightCommandRequest(key=st.key, has_state=True, state=False)))
check("off", daemon.take(), ["status off"])
for eff, words in (("Solid", "solid"), ("Blink", "blink slow"), ("Fast blink", "blink fast"), ("Heartbeat", "heartbeat")):
    list(st.handle_message(pb.LightCommandRequest(key=st.key, has_state=True, state=True, has_rgb=True, red=0.0, green=0.0,
                                                  blue=1.0, has_effect=True, effect=eff)))
    check("effect " + eff, daemon.take(), ["status blue " + words])
list(st.handle_message(pb.LightCommandRequest(key=st.key, has_effect=True, effect="Rainbow")))
check("an unknown effect changes nothing", daemon.take(), [])
# the state file drives the light
for shown, want in (("blue heartbeat", (True, 0.0, 0.0, 1.0, "Heartbeat")), ("white blink slow", (True, 1.0, 1.0, 1.0, "Blink")),
                    ("blue blink boot", (True, 0.0, 0.0, 1.0, "Blink")),
                    ("green blink fast", (True, 0.0, 1.0, 0.0, "Fast blink")), ("off solid", (False,))):
    setstate(shown=shown)
    st.poll()
    check("shown %r" % shown, (st.is_on, st.red, st.green, st.blue, st.effect)[:len(want)], want)
setstate(shown="magenta solid"); setstate(shown="garbage")
check("a garbage state line sends nothing", st.poll(), None)
# a refused command (the boot is not good): the poll shows the real state
setstate(boot="wait", shown="blue blink boot"); st.poll()
daemon.answer = b"err boot-wait\n"
cmd(state=True, red=1.0, green=0.0, blue=0.0)
check("the command went to the daemon (the effect stays)", daemon.take(), ["status red blink slow"])
r = st.poll()
check("refused: the next poll sends the real state", (r.state, r.red, r.green, r.blue), (True, 0.0, 0.0, 1.0))
daemon.answer = b"ok\n"

# ---- the diagnostic text
txt = by["status_led_control"]
os.unlink(t + "/run/state")
check("no state file: the daemon is not running", txt._get_state(), "Unavailable (uc-pxx-leds is not running)")
check("and the lights keep their state", (st.poll(), teams.poll()), (None, None))
setstate(boot="ok"); check("ok", txt._get_state(), "Free")
setstate(boot="wait"); check("wait", txt._get_state(), "Boot (the boot is not marked good yet, slow blue blink)")
setstate(boot="locked"); check("locked", txt._get_state(), "Locked (slot A was changed in this boot, slow blue blink)")
setstate(boot="ok", red="latched"); check("red latched", txt._get_state(), "Free, red LED latched")
setstate(boot="x"); check("unknown", txt._get_state(), "Unknown")

# ---- the daemon is not there
daemon.stop()
os.unlink(t + "/run/sock")
setstate(teams="off"); plugins.poll([teams])
out = list(teams.handle_message(pb.LightCommandRequest(key=teams.key, has_state=True, state=True)))
check("no daemon: the command is dropped with a log line, no error", (len(out), mod.send("get")), (1, False))

# ---- parts that are missing
mkleds(missing=("teams_white", "mute_headset"))
check("no LEDs for two indicators: no light for them",
      sorted(e.object_id for e in build()), ["mic_mute_led", "speaker_led", "status_led", "status_led_control"])
mkleds(missing=("blue",))
check("no blue LED: no status LED and no text sensor",
      sorted(e.object_id for e in build()), ["headset_led", "mic_mute_led", "speaker_led", "teams_led"])
mkleds(missing=("teams_white", "mute_headset", "mute_speaker", "mute_red", "red", "green", "blue"))
check("no LEDs: no entity", build(), [])

# ---- the file modes
import stat  # noqa: E402
check("the plugin file is not writable by the group", stat.S_IMODE(os.stat(t + "/pd/good/uc-pxx-leds.py").st_mode) & 0o022, 0)
src = open(prog).read()
check("the plugin never opens a file for writing", ('"w"' in src, "'w'" in src, "O_WRONLY" in src), (False, False, False))

print("%d failed" % fails)
sys.exit(1 if fails else 0)
