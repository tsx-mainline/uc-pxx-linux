# Checks of the module uc-pxx-leds (called by test-daemon.sh). The environment
# of the script points to a made-up /sys/class/leds in a temporary folder.
import importlib.machinery
import importlib.util
import os
import shutil
import sys

prog, t = sys.argv[1:3]
loader = importlib.machinery.SourceFileLoader("leds", prog)
spec = importlib.util.spec_from_loader("leds", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

fails = 0


def check(name, got, want):
    global fails
    if got == want:
        print("  ok:", name)
    else:
        print("  FAIL:", name, "(got %r, want %r)" % (got, want))
        fails += 1


def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fobj:
        fobj.write(text)


def get(path, default=None):
    try:
        with open(path) as fobj:
            return fobj.read().strip()
    except OSError:
        return default


ALL = ("teams_white", "mute_headset", "mute_speaker", "mute_red", "red", "green", "blue")
TRIG = "[none] timer heartbeat default-on\n"


def mkleds(red=0, trigger=TRIG, missing=()):
    shutil.rmtree(t + "/leds", ignore_errors=True)
    for name in ALL:
        if name in missing:
            continue
        put("%s/leds/%s/brightness" % (t, name), "0\n")
        put("%s/leds/%s/trigger" % (t, name), trigger)
    put(t + "/leds/red/brightness", "%d\n" % red)


def led(name):
    return int(get("%s/leds/%s/brightness" % (t, name), "-1"))


def trig(name):
    return get("%s/leds/%s/trigger" % (t, name))


def bootctl(succ, rc=0):
    """What the stub of uc-pxx-bootctl prints. succ is 0, 1 or None (no line)."""
    put(t + "/bootctl.succ", "" if succ is None else str(succ))
    put(t + "/bootctl.rc", str(rc))


def mark(on):
    if on:
        put(t + "/mark", "")
    elif os.path.exists(t + "/mark"):
        os.unlink(t + "/mark")


def fresh(red=0, ok=True, conf=None, **kw):
    """A new daemon object with made-up LEDs. It has run its first step."""
    mkleds(red, **kw)
    mark(False)
    for p in ("conf", "saved", "state"):
        if os.path.exists("%s/%s" % (t, p)):
            os.unlink("%s/%s" % (t, p))
    if conf:
        put(t + "/conf", conf)
    bootctl(1 if ok else 0)
    leds = m.Leds()
    leds.clock = lambda: NOW[0]
    at(leds, 1000.0)
    return leds


NOW = [1000.0]


def at(leds, now):
    """One step of the daemon at the time NOW (a made-up clock)."""
    NOW[0] = now
    return leds.tick(now)


def state(leds):
    return dict(line.split(None, 1) for line in leds.state_text().splitlines())


# ---- the parser
good = {
    "ind teams on": ("ind", "teams", "on", None), "ind headset off": ("ind", "headset", "off", None),
    "ind speaker blink": ("ind", "speaker", "blink", "slow"), "ind mic blink fast": ("ind", "mic", "blink", "fast"),
    "ind mic blink slow": ("ind", "mic", "blink", "slow"),
    "status auto": ("status", None), "status off": ("status", ("off", "solid", None)),
    "status red": ("status", ("red", "solid", None)), "status cyan solid": ("status", ("cyan", "solid", None)),
    "status blue heartbeat": ("status", ("blue", "heartbeat", None)),
    "status white blink": ("status", ("white", "blink", "slow")),
    "status yellow blink fast": ("status", ("yellow", "blink", "fast")), "get": ("get",),
    "  status   green  ": ("status", ("green", "solid", None)),
}
for line, want in good.items():
    check("parse %r" % line, m.parse(line), want)
bad = ["", " ", "ind", "ind teams", "ind teams blink medium", "ind teams on fast", "ind teams heartbeat", "ind tv on",
       "ind teams on; reboot", "status", "status pink", "status off blink", "status auto solid", "status red solid fast",
       "status red heartbeat slow", "status red 1", "status 1 0 0", "key 1 on", "get all", "GET", "ind TEAMS on",
       "x" * 200, "ind teams on\x00", "ind teams on\r", "ind teams on\t", "ind teams on\x07", "ind teams oné",
       "$(reboot)", "ind teams `x`", "status red\nstatus blue"]
for line in bad:
    try:
        m.parse(line)
        check("refused %r" % line[:24], "accepted", "refused")
    except m.Bad:
        check("refused %r" % line[:24], "refused", "refused")
check("pattern: slow blink", [m.pattern("blink", "slow", x)[0] for x in (0.0, 0.4, 0.6, 1.1)], [1, 1, 0, 1])
check("pattern: fast blink", [m.pattern("blink", "fast", x)[0] for x in (0.0, 0.1, 0.13, 0.26)], [1, 1, 0, 1])
check("pattern: heartbeat has two pulses", [m.pattern("heartbeat", None, x)[0] for x in (0.0, 0.1, 0.25, 0.3, 0.5)], [1, 0, 1, 0, 0])
check("pattern: the wait is the time to the edge", round(m.pattern("blink", "slow", 0.2)[1], 3), 0.3)
check("pattern: the boot blink is 0.5 s on, 1.5 s off", [m.pattern("blink", "boot", x)[0] for x in (0.0, 0.4, 0.6, 1.9, 2.1)],
      [1, 1, 0, 0, 1])


def delays(name):
    return (get("%s/leds/%s/delay_on" % (t, name)), get("%s/leds/%s/delay_off" % (t, name)))


# ---- the start: indicators off, slow blue blink while the boot is not good
L = fresh(ok=False)
check("boot wait at the start", L.boot, "wait")
check("all indicators are off and have no trigger", [(led(x), trig(x)) for x in ALL[:4]], [(0, "none")] * 4)
check("slow blue blink, green off", (trig("blue"), delays("blue"), led("green")), ("timer", ("500", "1500"), 0))
check("red is not touched while the boot is not good", (led("red"), trig("red")), (0, TRIG.strip()))
check("the state file", state(L)["boot"], "wait")
check("shown is blue blink boot", state(L)["shown"], "blue blink boot")
check("a status command is refused", (L.handle("status red"), L.status), ("err boot-wait", None))
check("status auto is accepted", L.handle("status auto"), "ok")
check("a bad line is refused", L.handle("nonsense"), "err bad-command")
check("a line with a control character", L.handle("get\x01"), "err bad-line")
check("indicators work during the boot wait", (L.handle("ind teams on"), led("teams_white")), ("ok", 1))
# the poll interval: the boot is asked again only when it is due
bootctl(1)
at(L, 1000.0 + m.POLL_WAIT - 1)
check("not due yet: still wait", L.boot, "wait")
at(L, 1000.0 + m.POLL_WAIT + 1)
check("slot A is successful: boot ok", L.boot, "ok")
check("solid green, blue off and no trigger", (led("green"), led("blue"), trig("blue")), (1, 0, "none"))
check("shown is green solid", state(L)["shown"], "green solid")
check("the next poll is later when the boot is ok", L.boot_due, 1000.0 + m.POLL_WAIT + 1 + m.POLL_OK)
OK_AT = 1000.0 + m.POLL_WAIT + 1
check("the step wakes up at the end of the green hold", round(at(L, OK_AT + m.HOLD_DEFAULT - 0.2), 3), 0.2)
check("green during the hold", (led("green"), state(L)["shown"]), (1, "green solid"))
at(L, OK_AT + m.HOLD_DEFAULT)
check("after the hold: the status LED is off", ([led(x) for x in ("red", "green", "blue")], state(L)["shown"], state(L)["status"]),
      ([0, 0, 0], "off solid", "auto"))
check("status auto: still off after the hold", (L.handle("status auto"), led("green")), ("ok", 0))
check("a status command after the hold", (L.handle("status cyan"), led("green"), led("blue")), ("ok", 1, 1))
check("status auto: the boot display, off", (L.handle("status auto"), led("green"), led("blue")), ("ok", 0, 0))
bootctl(None)                       # unknown state: wait
L.boot_due = 0; at(L, 2000.0)
check("no 'current' line from bootctl: wait", L.boot, "wait")
bootctl(1, rc=1)
L.boot_due = 0; at(L, 2001.0)
check("bootctl fails: wait", L.boot, "wait")
bootctl(1)
L.boot_due = 0; at(L, 2002.0)
check("and ok again", L.boot, "ok")

# ---- the indicators
L = fresh()
for who, name in (("teams", "teams_white"), ("headset", "mute_headset"), ("speaker", "mute_speaker"), ("mic", "mute_red")):
    check("%s on" % who, (L.handle("ind %s on" % who), led(name), trig(name)), ("ok", 1, "none"))
    check("%s blink" % who, (L.handle("ind %s blink" % who), trig(name), get("%s/leds/%s/delay_on" % (t, name)),
                             get("%s/leds/%s/delay_off" % (t, name))), ("ok", "timer", "500", "500"))
    check("%s blink fast" % who, (L.handle("ind %s blink fast" % who), get("%s/leds/%s/delay_on" % (t, name))), ("ok", "125"))
    check("%s off" % who, (L.handle("ind %s off" % who), led(name), trig(name)), ("ok", 0, "none"))
    check("%s state" % who, state(L)[who], "off")
check("only the named LED changes", [led(x) for x in ALL], [0, 0, 0, 0, 0, 1, 0])
L.handle("ind speaker blink fast")
check("the state file says blink fast", state(L)["speaker"], "blink fast")
check("mute_red is the Mic indicator and does not touch the status red", (L.handle("ind mic on"), led("mute_red"), led("red"), L.red_latched), ("ok", 1, 0, False))

# ---- the status LED colors
L = fresh()
for color, want in (("red", (1, 0, 0)), ("green", (0, 1, 0)), ("blue", (0, 0, 1)), ("yellow", (1, 1, 0)),
                    ("cyan", (0, 1, 1)), ("magenta", (1, 0, 1)), ("white", (1, 1, 1)), ("off", (0, 0, 0))):
    check("status %s" % color, (L.handle("status " + color), tuple(led(x) for x in ("red", "green", "blue"))), ("ok", want))
    check("status %s: no trigger" % color, [trig(x) for x in ("green", "blue")], ["none", "none"])
    check("status %s: shown" % color, state(L)["shown"], color + " solid")
check("status auto goes back to green", (L.handle("status auto"), led("green"), state(L)["status"], state(L)["shown"]),
      ("ok", 1, "auto", "green solid"))
# modes with kernel triggers (no red part)
L.handle("status blue heartbeat")
check("blue heartbeat uses the kernel trigger", (trig("blue"), led("green"), state(L)["shown"]), ("heartbeat", 0, "blue heartbeat"))
L.handle("status cyan blink")
check("cyan blink: timer on green and blue", (trig("green"), trig("blue"), get(t + "/leds/blue/delay_on")), ("timer", "timer", "500"))
L.handle("status green blink fast")
check("green blink fast: 125 ms, blue off without trigger", (trig("green"), get(t + "/leds/green/delay_on"), trig("blue"), led("blue")),
      ("timer", "125", "none", 0))
check("shown: green blink fast", state(L)["shown"], "green blink fast")
L.handle("status green")
check("back to solid: no trigger, on", (trig("green"), led("green")), ("none", 1))

# ---- red patterns are made by the daemon, without a kernel trigger
L = fresh()
L.handle("status yellow blink")
w = at(L, 5000.0)
check("yellow blink: red is on at the start of the cycle", led("red"), 1)
check("yellow blink: green has the kernel timer", trig("green"), "timer")
check("the red LED has no trigger written", trig("red"), TRIG.strip())
check("the next step is at the edge", round(w, 3), 0.5)
at(L, 5000.6)
check("red is off in the second half", led("red"), 0)
at(L, 5001.1)
check("red is on again", led("red"), 1)
L.handle("status red heartbeat")
at(L, 7000.0); a = led("red"); at(L, 7000.1); b = led("red"); at(L, 7000.25); c = led("red")
check("red heartbeat: pulse, gap, pulse", (a, b, c), (1, 0, 1))
check("red is never put under a trigger", trig("red"), TRIG.strip())
L.handle("status auto")
check("status auto: red goes off (it was ours)", led("red"), 0)

# ---- the red latch
L = fresh(red=1)
check("red on at the start: latched", (L.red_latched, state(L)["red"]), (True, "latched"))
L.handle("status off"); check("latched: status off leaves red on", led("red"), 1)
L.handle("status yellow"); check("latched: green changes, red stays", (led("red"), led("green")), (1, 1))
L.handle("status blue blink"); check("latched: blue blinks, red stays on", (led("red"), trig("blue")), (1, "timer"))
check("latched: shown includes red", state(L)["shown"], "magenta solid")
put(t + "/leds/red/brightness", "0\n"); at(L, 1001.0)
check("a person cleared red: the latch ends", (L.red_latched, state(L)["red"]), (False, "free"))
L.handle("status red"); check("then the daemon may light red", (led("red"), L.red_latched), (1, False))
L.handle("status off"); check("and switch its own red off", (led("red"), L.red_latched), (0, False))
L = fresh()
put(t + "/leds/red/brightness", "1\n"); at(L, 1001.0)
check("red lit by another program: latched", (L.red_latched, led("red")), (True, 1))
L.handle("status off"); L.handle("status auto"); L.handle("status green")
check("no command clears it", led("red"), 1)
L = fresh(); L.handle("status red")
check("our own red: free", (led("red"), L.red_latched), (1, False))
put(t + "/leds/red/brightness", "0\n"); at(L, 1001.0)
check("somebody cleared our red: no latch, we write it again", (L.red_latched, led("red")), (False, 1))
# a red that the daemon wants off, lit by a script in the same moment
L = fresh()
put(t + "/leds/red/brightness", "1\n"); L.handle("status auto")
check("a script lights red while the daemon wants it off: it stays on", (L.red_latched, led("red")), (True, 1))

# ---- the safety rule: red is never written while the boot is not good
L = fresh(); L.handle("status red")
mark(True); at(L, 1002.0)
check("the marker: boot locked", L.boot, "locked")
check("the user's red stays on (nothing is written)", led("red"), 1)
check("slow blue blink, green off", (trig("blue"), led("green")), ("timer", 0))
check("shown: red lit plus blue blink", state(L)["shown"], "magenta solid")
check("status refused when locked", L.handle("status off"), "err boot-locked")
check("indicators still work when locked", L.handle("ind teams on"), "ok")
check("state file says locked", state(L)["boot"], "locked")
L.handle("status auto")
check("status auto does not touch red when locked", led("red"), 1)
mark(False); at(L, 1003.0)
check("the marker is gone and bootctl says ok: boot ok again", L.boot, "ok")
check("status auto is in effect: red goes off (it was ours)", (led("red"), led("green")), (0, 1))
# a marker at the start
mkleds(); mark(True); bootctl(1); L = m.Leds(); L.clock = lambda: NOW[0]; at(L, 1.0)
check("marker at the start: locked, no bootctl needed", (L.boot, trig("blue")), ("locked", "timer"))
mark(False)

# ---- no kernel trigger: the daemon blinks in software
L = fresh(trigger="[none]\n")
L.handle("ind teams blink")
w = at(L, 10.0); a = led("teams_white")
at(L, 10.6); b = led("teams_white")
check("software blink toggles the LED", (a, b), (1, 0))
check("and wakes up for the next edge", w <= 0.5, True)
L.handle("ind teams on")
check("solid again", (led("teams_white"), L.applied["teams_white"]), (1, ("none",)))

# ---- missing LEDs
L = fresh(missing=("blue", "teams_white"))
check("a missing LED: commands still work", (L.handle("status white"), L.handle("ind teams on"), led("green"), led("red")), ("ok", "ok", 1, 1))
shutil.rmtree(t + "/leds")
L = m.Leds(); L.clock = lambda: NOW[0]; at(L, 1.0)
check("no LED folder: no crash, red free", (L.handle("status red"), L.red_latched), ("ok", False))

# ---- persistence
L = fresh(conf="PERSIST=no\n")
L.handle("ind teams on"); L.handle("status red")
check("PERSIST=no: nothing is saved", os.path.exists(t + "/saved"), False)
L = fresh(conf='# comment\nPERSIST="yes"\n')
check("PERSIST=yes", L.persist, True)
L.handle("ind teams on"); L.handle("ind mic blink fast"); L.handle("status magenta blink slow")
check("the saved commands", get(t + "/saved").splitlines(),
      ["ind teams on", "ind headset off", "ind speaker off", "ind mic blink fast", "status magenta blink slow"])
check("the saved file is not left as a .tmp", os.path.exists(t + "/saved.tmp"), False)
saved = get(t + "/saved")
mkleds(); put(t + "/conf", "PERSIST=yes\n"); put(t + "/saved", saved + "\n"); bootctl(0)
L = m.Leds(); L.clock = lambda: NOW[0]; at(L, 1000.0)
check("after a restart the indicators come back", (led("teams_white"), trig("mute_red"), state(L)["mic"]), (1, "timer", "blink fast"))
check("the status LED shows the boot state, not the saved color, until the boot is good", (state(L)["shown"], state(L)["status"]),
      ("blue blink boot", "magenta blink slow"))
bootctl(1); L.boot_due = 0; at(L, 1001.0)
check("boot ok: the saved status plays back", (state(L)["shown"], led("red")), ("magenta blink slow", 1))
put(t + "/saved", "ind teams on\nrm -rf /\nstatus pink\nind tv on\nstatus red heartbeat\n"); put(t + "/conf", "PERSIST=yes\n")
mkleds(); bootctl(1); L = m.Leds()
check("bad lines in the saved file are skipped, good ones are used", (L.ind["teams"], L.status), (("on", None), ("red", "heartbeat", None)))
put(t + "/conf", "PERSIST=no\n"); L.read_conf()
check("a reload reads the setting again", L.persist, False)

# ---- the green hold setting
L = fresh(conf="BOOT_OK_HOLD_S=0\n")
check("BOOT_OK_HOLD_S=0", L.hold, 0)
at(L, 1000.0 + 3600)
check("BOOT_OK_HOLD_S=0: green stays on", (led("green"), state(L)["shown"]), (1, "green solid"))
L = fresh(conf='BOOT_OK_HOLD_S="3"\n')
at(L, 1002.9); a = led("green"); at(L, 1003.0); b = led("green")
check("BOOT_OK_HOLD_S=3: green for 3 s, then off", (L.hold, a, b), (3, 1, 0))
L = fresh(conf="BOOT_OK_HOLD_S=soon\n")
check("a bad BOOT_OK_HOLD_S: the default", L.hold, m.HOLD_DEFAULT)
L = fresh(conf="BOOT_OK_HOLD_S=-1\n")
check("a negative BOOT_OK_HOLD_S: the default", L.hold, m.HOLD_DEFAULT)
L = fresh()
at(L, 1000.0 + m.HOLD_DEFAULT + 1)
check("default hold: off after 10 s", led("green"), 0)
mark(True); at(L, 1020.0)
check("locked after the hold: the slow blue blink again", (trig("blue"), led("green")), ("timer", 0))
mark(False); at(L, 1021.0)
check("ok again: green for a new hold", (L.boot, led("green")), ("ok", 1))
at(L, 1021.0 + m.HOLD_DEFAULT)
check("and off after it", led("green"), 0)
L = fresh(red=1)
at(L, 1000.0 + m.HOLD_DEFAULT + 1)
check("after the hold a latched red stays on", (led("red"), L.red_latched, state(L)["shown"]), (1, True, "red solid"))
put(t + "/conf", "BOOT_OK_HOLD_S=0\n"); L.read_conf(); at(L, 1100.0)
check("a reload reads BOOT_OK_HOLD_S again", (L.hold, led("green")), (0, 1))

# ---- the state file and get
L = fresh()
check("get returns the state text", L.handle("get"), L.state_text().rstrip("\n"))
check("the state file is written", get(t + "/state"), L.state_text().strip())
check("the keys of the state file", [l.split()[0] for l in L.state_text().splitlines()],
      ["boot", "red", "teams", "headset", "speaker", "mic", "status", "shown", "persist"])
check("the mode of the state file", oct(os.stat(t + "/state").st_mode & 0o777), "0o644")

print("%d failed" % fails)
sys.exit(1 if fails else 0)
