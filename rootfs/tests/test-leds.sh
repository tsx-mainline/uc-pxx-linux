#!/bin/sh
# Host test for uc-pxx-leds, the root helper of the LEDs that Home Assistant
# controls. It uses a made-up /sys/class/leds, a stub for tsx-keypad, a made-up
# boot state file and a real FIFO. It checks:
#   - the commands: only the fixed forms run, anything else is refused
#   - the key LED commands call tsx-keypad with fixed arguments
#   - the status LED: refused until the boot is marked good, refused when the
#     marker of a changed slot A exists
#   - the red LED: a latch when another program lit it, never written while it
#     is latched, free again when a person cleared it
#   - the FIFO and the state file of the daemon
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROG=$HERE/overlay/usr/local/sbin/uc-pxx-leds
INIT=$HERE/overlay/etc/init.d/uc-pxx-leds
T=$(mktemp -d); trap 'rm -rf "$T"; kill $BG 2>/dev/null' EXIT
BG=
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: no python3"; exit 0; }

echo "== syntax =="
python3 -I -B -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PROG" && ok "uc-pxx-leds parses" || bad "uc-pxx-leds: parse"
busybox sh -n "$INIT" && ok "the init script passes busybox sh -n" || bad "the init script: busybox sh -n"
[ -x "$PROG" ] && [ -x "$INIT" ] && ok "both files are executable" || bad "a file is not executable"
head -n 1 "$INIT" | grep -qx '#!/sbin/openrc-run' && ok "the init script is an OpenRC script" || bad "no openrc-run line"

mkdir -p "$T/run"
cat > "$T/keypad" <<'S'
#!/bin/sh
echo "$*" >> "$(dirname "$0")/keypad.calls"
S
chmod +x "$T/keypad"
ENVV="UC_PXX_LEDS=$T/leds UC_PXX_LEDS_FIFO=$T/run/f UC_PXX_LEDS_STATE=$T/run/state UC_PXX_LED_STATE=$T/boot.state UC_PXX_SLOT_MARK=$T/mark UC_PXX_KEYPAD=$T/keypad TSX_RUN_DIR=$T/run"

echo "== the module, with a made-up system =="
env -i PATH="$PATH" $ENVV python3 -I -B - "$PROG" "$T" <<'PY'
import importlib.machinery, importlib.util, os, shutil, sys
prog, t = sys.argv[1:3]
loader = importlib.machinery.SourceFileLoader("leds", prog)
spec = importlib.util.spec_from_loader("leds", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print("  ok:", name)
    else:
        print("  FAIL:", name, "(got %r, want %r)" % (got, want)); fails += 1
def put(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(s)
def mkleds(red=0):
    shutil.rmtree(t + "/leds", ignore_errors=True)
    for l in ("green", "red", "blue"):
        put("%s/leds/%s/brightness" % (t, l), "0\n"); put("%s/leds/%s/trigger" % (t, l), "[none] heartbeat\n")
    put(t + "/leds/red/brightness", "%d\n" % red)
    put(t + "/leds/blue/trigger", "none [heartbeat]\n")
def led(l): return int(open("%s/leds/%s/brightness" % (t, l)).read())
def trig(l): return open("%s/leds/%s/trigger" % (t, l)).read().strip()
def boot(s):
    if s is None:
        if os.path.exists(t + "/boot.state"): os.unlink(t + "/boot.state")
    else: put(t + "/boot.state", "boot %s\n" % s)
def mark(on):
    if on: put(t + "/mark", "")
    elif os.path.exists(t + "/mark"): os.unlink(t + "/mark")
def calls():
    try:
        out = open(t + "/keypad.calls").read().splitlines()
        os.unlink(t + "/keypad.calls")
        return out
    except OSError:
        return []

# ---- the key commands
mkleds(); boot("ok"); mark(False); L = m.Leds()
good = {"key 1 on": ["key 1 on"], "key 2 off": ["key 2 off"], "key 3 auto": ["key 3 auto"], "key 4 on": ["key 4 on"],
        "keys auto": ["key %d auto" % i for i in (1, 2, 3, 4)]}
for line, want in good.items():
    check("%r runs tsx-keypad" % line, (L.handle(line), calls()), (True, want))
bad = ["key 5 on", "key 0 on", "key 1 maybe", "key 1 on; reboot", "key 1", "keys on", "keys", "status 2 0 0", "status 1 0",
       "status 1 0 1 1", "status a b c", "led 40", "", "KEY 1 on", "key 01 on", "key\t1 on", "key 1 on\x00", "x" * 200,
       "key 1 oné", "key -1 on", "key 1 on\r", "$(reboot)", "key 1 on `x`", "status 1 0 1\x07"]
for line in bad:
    check("refused: %r" % line[:24], (L.handle(line), calls()), (False, []))
check("a failing tsx-keypad is False", (m.KEYPAD, ), (t + "/keypad",))

# ---- the status LED and its gate
mkleds(); mark(False); boot(None); L = m.Leds()
check("no state file: refused", (L.gate(), L.handle("status 0 1 0"), led("green")), ("boot", False, 0))
boot("wait"); check("boot wait: refused", (L.gate(), L.handle("status 0 1 0"), led("green")), ("boot", False, 0))
put(t + "/boot.state", "garbage\n"); check("a bad state file: refused", (L.gate(), L.handle("status 0 1 0")), ("boot", False))
boot("ok"); check("boot ok: allowed", (L.gate(), L.handle("status 0 1 0"), led("green"), led("blue"), led("red")), ("ha", True, 1, 0, 0))
check("blue heartbeat is replaced by none", (L.handle("status 0 0 1"), led("blue"), trig("blue"), led("green")), (True, 1, "none", 0))
for line, want in (("status 0 1 1", (0, 1, 1)), ("status 1 0 1", (1, 0, 1)), ("status 1 1 0", (1, 1, 0)),
                   ("status 1 1 1", (1, 1, 1)), ("status 1 0 0", (1, 0, 0)), ("status 0 0 0", (0, 0, 0))):
    L.handle(line); check(line, (led("red"), led("green"), led("blue")), want)
mark(True)
check("the marker of a changed slot A: refused", (L.gate(), L.handle("status 1 1 1"), led("red"), led("green")), ("locked", False, 0, 0))
check("the marker does not block the key LEDs", (L.handle("key 1 off"), calls()), (True, ["key 1 off"]))
mark(False); boot("wait")
check("the boot state goes back to wait: refused again", L.handle("status 1 1 1"), False)

# ---- the red LED
boot("ok")
mkleds(red=1); L = m.Leds()
check("red on at the start: latched", L.red_latched, True)
L.handle("status 0 0 0"); check("latched: status off leaves red on", led("red"), 1)
L.handle("status 0 1 0"); check("latched: green still changes, red stays", (led("red"), led("green")), (1, 1))
L.handle("status 0 0 1"); check("latched: blue changes", (led("red"), led("blue")), (1, 1))
put(t + "/leds/red/brightness", "0\n")
L.publish(); check("a person cleared red: the latch ends", L.red_latched, False)
L.handle("status 1 0 0"); check("after that, Home Assistant may light red", led("red"), 1)
L.handle("status 0 0 0"); check("and switch its own red off", (led("red"), L.red_latched), (0, False))

mkleds(); L = m.Leds()
check("red off at the start: free", L.red_latched, False)
put(t + "/leds/red/brightness", "1\n")     # a boot-control script lights red
L.handle("status 0 1 0"); check("red lit by another program: latched, not written", (L.red_latched, led("red")), (True, 1))
L.handle("status 0 0 0"); check("status off does not clear it", led("red"), 1)
mkleds(); L = m.Leds(); L.handle("status 1 1 1"); check("our own red: free", (led("red"), L.red_latched), (1, False))
put(t + "/leds/red/brightness", "0\n"); L.handle("status 0 0 0")
check("somebody cleared our red: no latch", (led("red"), L.red_latched), (0, False))
mkleds(); L = m.Leds(); L.handle("status 1 0 0")
put(t + "/leds/red/brightness", "0\n"); put(t + "/leds/red/brightness", "1\n")
check("red was ours and is still on: free", L.red_check(), 1); check("no latch", L.red_latched, False)

# ---- a missing LED
shutil.rmtree(t + "/leds"); mkleds(); shutil.rmtree(t + "/leds/blue"); L = m.Leds()
check("no blue LED: the command still works for the others", (L.handle("status 1 1 1"), led("green"), led("red")), (True, 1, 1))
shutil.rmtree(t + "/leds"); L = m.Leds()
check("no LED folder at all: no crash, red unknown", (L.handle("status 1 1 1"), L.red_latched), (True, False))
print("%d failed" % fails)
sys.exit(1 if fails else 0)
PY
rc=$?; [ "$rc" = 0 ] && ok "the module checks" || bad "the module checks"

echo "== the daemon with a FIFO =="
GRP=$(id -gn)
mkdir -p "$T/leds/green" "$T/leds/red" "$T/leds/blue"; for l in green red blue; do echo 0 > "$T/leds/$l/brightness"; echo "[none]" > "$T/leds/$l/trigger"; done
echo "boot ok" > "$T/boot.state"; rm -f "$T/mark" "$T/keypad.calls"
env -i PATH="$PATH" $ENVV UC_PXX_LEDS_GROUPS="nosuchgroup $GRP" UC_PXX_LEDS_TICK=0.3 python3 -I -B "$PROG" 2> "$T/daemon.log" &
BG=$!
i=0; while [ ! -p "$T/run/f" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -p "$T/run/f" ] && ok "the FIFO exists" || bad "no FIFO"
eq "$(stat -c %a "$T/run/f")" "660" "the FIFO has mode 660 (group of the list)"
eq "$(stat -c %G "$T/run/f")" "$GRP" "the FIFO has the group from the list"
sleep 0.5
printf 'key 2 off\nstatus 0 1 0\nbogus\n' > "$T/run/f"
sleep 0.8
eq "$(cat "$T/keypad.calls" 2>/dev/null)" "key 2 off" "a line in the FIFO runs tsx-keypad"
eq "$(cat "$T/leds/green/brightness")" "1" "a status line lights green"
grep -q "refused: bogus" "$T/daemon.log" && ok "a bad line is refused and logged" || bad "no refusal in the log: $(cat "$T/daemon.log")"
eq "$(sed -n 1p "$T/run/state")" "status ha" "the state file says status ha"
eq "$(sed -n 2p "$T/run/state")" "red free" "the state file says red free"
[ "$(stat -c %a "$T/run/state")" = 644 ] && ok "the state file has mode 644" || bad "state file mode"
: > "$T/mark"; sleep 1.3
eq "$(sed -n 1p "$T/run/state")" "status locked" "the marker changes the state file to locked"
echo 1 > "$T/leds/red/brightness"; sleep 1.3
eq "$(sed -n 2p "$T/run/state")" "red latched" "red lit by another program: red latched"
kill -TERM $BG; wait $BG; eq "$?" "0" "SIGTERM ends the daemon with exit 0"; BG=
mkdir "$T/ro"; chmod 500 "$T/ro"
env -i PATH="$PATH" $ENVV UC_PXX_LEDS_FIFO="$T/ro/sub/f" python3 -I -B "$PROG" 2> "$T/daemon.log"; rc=$?
[ "$(id -u)" = 0 ] || eq "$rc" "1" "a FIFO that cannot be made: exit 1"
python3 -I -B "$PROG" bogus 2>/dev/null; eq "$?" "2" "a wrong argument: exit 2"

echo "$N passed, $F failed"
[ "$F" = 0 ]
