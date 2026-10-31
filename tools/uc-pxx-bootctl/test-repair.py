#!/usr/bin/env python3
"""Test `uc-pxx-bootctl repair` and `switch` against their own models (written here, not taken from the tool), and test that
the other commands behave exactly as in the old binary.

Usage: test-repair.py <binary> [--old <old binary>] [--full] [--sample N]
  --old    differential: every non-repair command must give the same exit code, stdout and sector as the
           old binary (the reviewed 5d83215b), on every case.
  --full   all 65,536 slot-field combinations (priority 0..15 x tries 0..7 x successful 0..1 x reserved 0..1
           per slot) for both keepers, with and without --dry-run. Use a native (x86-64) build for --full:
           under qemu it takes hours.
  --sample N  N random corrupted sectors (default 300).
Runs the binary directly; for aarch64 pass a qemu wrapper (as build.sh does)."""
import binascii, os, random, subprocess, sys, tempfile

args = sys.argv[1:]
BIN = args.pop(0)
OLD = None
FULL = False
SAMPLE = 300
while args:
    a = args.pop(0)
    if a == "--old":
        OLD = args.pop(0)
    elif a == "--full":
        FULL = True
    elif a == "--sample":
        SAMPLE = int(args.pop(0))
    else:
        sys.exit("unknown argument " + a)

MAGIC = b"\0AB0"


def crc_be(b):
    return (binascii.crc32(bytes(b[:28])) & 0xffffffff).to_bytes(4, "big")


def legal(s):
    p, t, ok, r = s
    if p > 15 or t > 7 or r != 0:
        return False
    if ok == 1:
        return t == 0
    return ok == 0


def bootable(s):
    return s[0] > 0 and (s[2] == 1 or s[1] > 0)


def successful(s):
    return s[2] == 1 and s[1] == 0 and s[0] >= 1


def valid(b):
    A, B = b[8:12], b[12:16]
    return (b[:4] == MAGIC and b[4] == 1 and b[6:8] == b"\0\0" and b[16:28] == bytes(12)
            and b[28:32] == crc_be(b) and legal(A) and legal(B) and (bootable(A) or bootable(B)))


def pick(b):
    a, bb = bootable(b[8:12]), bootable(b[12:16])
    if a and bb:
        return 1 if b[12] > b[8] else 0
    return 0 if a else 1 if bb else -1


def needs_repair(b, k):
    """The rule of DEVMODE-R4.md §2 with the owner's Q1 (§11): no repair only when the sector is valid
    and the keeper is successful. A keeper that boots next but only as trying is repaired too."""
    return not valid(b) or not successful(b[8 + 4 * k:12 + 4 * k])


def repaired(cur, k):
    """R(k): built byte by byte here, from the state table, not from the tool."""
    r = bytearray(cur)
    r[0:32] = bytes(32)
    r[0:4] = MAGIC
    r[4] = 1
    r[8 + 4 * k:12 + 4 * k] = bytes([15, 0, 1, 0])
    r[28:32] = crc_be(r)
    return bytes(r)


def run(binary, sector, *a):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "s.bin")
        with open(p, "wb") as f:
            f.write(sector)
        r = subprocess.run([binary, *a, "--file", p], capture_output=True, text=True)
        with open(p, "rb") as f:
            return r.returncode, f.read(), r.stdout, r.stderr.strip()


fails = 0
runs = 0


def fail(msg):
    global fails
    fails += 1
    if fails <= 40:
        print("FAIL", msg)


def check_repair(name, s):
    """One sector, both keepers, dry run and real run, against the model."""
    global runs
    hx = s.hex()
    for k in (0, 1):
        need = needs_repair(s, k)
        want = repaired(s, k)
        for dry in (True, False):
            a = ["repair", "--keeper", "ab"[k], "--expect-sector", hx] + (["--dry-run"] if dry else [])
            rc, after, out, err = run(BIN, s, *a)
            runs += 1
            tag = "%s keeper %s%s" % (name, "ab"[k], " dry" if dry else "")
            if not need:
                if rc != 0 or after != s or out != "repair: not-needed\n":
                    fail("%s: want not-needed (no write), got rc %d out %r changed %s %s" % (tag, rc, out, after != s, err))
                continue
            if dry:
                if rc != 0 or after != s or out != "repair: would-write %s\n" % want[:32].hex():
                    fail("%s: want would-write %s, got rc %d out %r changed %s" % (tag, want[:32].hex(), rc, out, after != s))
                continue
            ok = (rc == 0 and after == want and out == "repair: writing %s\nrepair: wrote %s\n" % (want[:32].hex(), want[:32].hex()))
            # the model's own checks of the result: only the keeper bootable, successful, valid, tail unchanged
            ok = ok and valid(after) and pick(after) == k and not bootable(after[8 + 4 * (1 - k):12 + 4 * (1 - k)])
            ok = ok and successful(after[8 + 4 * k:12 + 4 * k]) and after[32:] == s[32:]
            if not ok:
                fail("%s: want R = %s, got rc %d out %r after %s %s" % (tag, want[:32].hex(), rc, out, after[:32].hex(), err))
        # the guard: one other byte anywhere in the sector -> refused, untouched
        for pos in (0, 9, 31, 32, 511):
            g = bytearray(s)
            g[pos] ^= 0x01
            rc, after, out, err = run(BIN, s, "repair", "--keeper", "ab"[k], "--expect-sector", bytes(g).hex())
            runs += 1
            if rc != 1 or after != s or out:
                fail("%s keeper %s: --expect-sector differs at byte %d: want refused, got rc %d out %r" % (name, "ab"[k], pos, rc, out))
    check_switch(name, s)


def switched(cur, to):
    """The model of switch --to T: None = refused, "same" = nothing to do, else the new sector."""
    t, o = 8 + 4 * to, 8 + 4 * (1 - to)
    if not valid(cur) or not successful(cur[t:t + 4]) or not bootable(cur[o:o + 4]):
        return None
    if pick(cur) == to and cur[t] > cur[o]:
        return "same"
    r = bytearray(cur)
    r[t] = 15
    r[o] = min(r[o], 14)
    r[28:32] = crc_be(r)
    return bytes(r)


def check_switch(name, s):
    global runs
    hx = s.hex()
    for to in (0, 1):
        want = switched(s, to)
        for dry in (True, False):
            a = ["switch", "--to", "ab"[to], "--expect-sector", hx] + (["--dry-run"] if dry else [])
            rc, after, out, err = run(BIN, s, *a)
            runs += 1
            tag = "%s switch to %s%s" % (name, "ab"[to], " dry" if dry else "")
            if want is None:
                if rc != 1 or after != s or out:
                    fail("%s: want refused, got rc %d out %r %s" % (tag, rc, out, err))
            elif want == "same":
                if rc != 0 or after != s or out != "switch: not-needed\n":
                    fail("%s: want not-needed, got rc %d out %r" % (tag, rc, out))
            elif dry:
                if rc != 0 or after != s or out != "switch: would-write %s\n" % want[:32].hex():
                    fail("%s: want would-write %s, got rc %d out %r" % (tag, want[:32].hex(), rc, out))
            else:
                ok = rc == 0 and after == want and out == "switch: writing %s\nswitch: wrote %s\n" % (want[:32].hex(), want[:32].hex())
                o = 8 + 4 * (1 - to)
                ok = ok and valid(after) and pick(after) == to and bootable(after[o:o + 4]) and after[8 + 4 * to] > after[o]
                ok = ok and all(after[i] == s[i] for i in range(512) if i not in (8 + 4 * to, o, 28, 29, 30, 31))
                if not ok:
                    fail("%s: want %s, got rc %d out %r after %s %s" % (tag, want[:32].hex(), rc, out, after[:32].hex(), err))
        g = bytearray(s)
        g[300] ^= 1
        rc, after, out, _ = run(BIN, s, "switch", "--to", "ab"[to], "--expect-sector", bytes(g).hex())
        runs += 1
        if rc != 1 or after != s or out:
            fail("%s switch to %s: another --expect-sector: want refused, got rc %d" % (name, "ab"[to], rc))


def base():
    b = bytearray(512)
    b[:4] = MAGIC
    b[4] = 1
    b[8:12] = bytes([15, 0, 1, 0])
    b[12:16] = bytes([14, 0, 1, 0])
    for i in range(32, 512):
        b[i] = (i * 7 + 3) & 0xff        # a tail that is not zero: it must come back unchanged
    b[28:32] = crc_be(b)
    return bytes(b)


def mk(A, B, tail=None):
    b = bytearray(base() if tail is None else tail)
    b[:4], b[4], b[5], b[6:8], b[16:28] = MAGIC, 1, 0, b"\0\0", bytes(12)
    b[8:12], b[12:16] = bytes(A), bytes(B)
    b[28:32] = crc_be(b)
    return bytes(b)


B0 = base()
cases = {
    "S0 A15 B14 succ": mk([15, 0, 1, 0], [14, 0, 1, 0]),
    "D1 A15 succ B disabled": mk([15, 0, 1, 0], [0, 0, 0, 0]),
    "D2 A14 succ B 15,7,0": mk([14, 0, 1, 0], [15, 7, 0, 0]),
    "R(a)": repaired(B0, 0),
    "R(b)": repaired(B0, 1),
    "bad magic": bytes(b"\0AX0") + B0[4:],
    "version 2": B0[:4] + b"\x02" + B0[5:28] + crc_be(B0[:4] + b"\x02" + B0[5:28]) + B0[32:],
    "LE crc": B0[:28] + (binascii.crc32(B0[:28]) & 0xffffffff).to_bytes(4, "little") + B0[32:],
    "crc off by one": B0[:31] + bytes([B0[31] ^ 1]) + B0[32:],
    "reserved 20 set": (lambda b: b[:28] + crc_be(b) + b[32:])(B0[:20] + b"\x01" + B0[21:]),
    "A succ1 tries1 (unit-1 brick)": mk([15, 1, 1, 0], [14, 0, 1, 0]),
    "no bootable slot": mk([15, 0, 0, 0], [14, 0, 0, 0]),
    "both disabled": mk([0, 0, 0, 0], [0, 0, 0, 0]),
    "all zero": bytes(512),
    "all ff": b"\xff" * 512,
    "half torn S0 -> D1 (16 new bytes)": mk([15, 0, 1, 0], [0, 0, 0, 0])[:16] + mk([15, 0, 1, 0], [14, 0, 1, 0])[16:],
    "B trying picked, A not bootable": mk([0, 0, 0, 0], [15, 7, 0, 0]),
    "B succ picked, A trying 14": mk([14, 3, 0, 0], [15, 0, 1, 0]),
    "A trying picked, B disabled": mk([15, 3, 0, 0], [0, 0, 0, 0]),
    "A trying 1, B succ 15": mk([14, 1, 0, 0], [15, 0, 1, 0]),
    "tie A succ 15 B trying 15": mk([15, 0, 1, 0], [15, 7, 0, 0]),
    "A succ prio 0 (not a keeper)": mk([0, 0, 1, 0], [14, 0, 1, 0]),
    "tie both succ 15": mk([15, 0, 1, 0], [15, 0, 1, 0]),
    "A succ 3, B succ 2": mk([3, 0, 1, 0], [2, 0, 1, 0]),
    "A succ 15, B trying 14": mk([15, 0, 1, 0], [14, 5, 0, 0]),
}
for name, s in cases.items():
    check_repair(name, s)
print(f"named cases: {len(cases)} sectors, {runs} runs, {fails} failures")

rnd = random.Random(20261031)
for i in range(SAMPLE):
    s = bytearray(mk([rnd.randrange(17), rnd.randrange(9), rnd.randrange(3), rnd.randrange(2)],
                     [rnd.randrange(17), rnd.randrange(9), rnd.randrange(3), rnd.randrange(2)]))
    how = rnd.randrange(5)
    if how == 1:                                  # a flipped byte in 0..31 (CRC then mostly wrong)
        s[rnd.randrange(32)] ^= 1 << rnd.randrange(8)
    elif how == 2:                                # a torn write: a prefix of another sector
        o = mk([rnd.randrange(16), 0, 1, 0], [0, 0, 0, 0])
        n = rnd.randrange(1, 512)
        s[:n] = o[:n]
    elif how == 3:                                # random bytes
        s = bytearray(rnd.randbytes(512))
    check_repair("random %d" % i, bytes(s))
print(f"after the random sample: {runs} runs, {fails} failures")

if FULL:
    n0 = runs
    for a in range(256):
        for b in range(256):
            A = [a >> 4, (a >> 1) & 7, a & 1, 0]
            B = [b >> 4, (b >> 1) & 7, b & 1, 0]
            check_repair("full A%s B%s" % (A, B), mk(A, B))
    # the reserved byte and the out-of-range values: a few more each
    for A in ([15, 0, 1, 1], [16, 0, 1, 0], [15, 8, 0, 0], [15, 0, 2, 0]):
        for B in ([14, 0, 1, 0], [0, 0, 0, 0], [15, 7, 0, 0]):
            check_repair("range A%s B%s" % (A, B), mk(A, B))
    print(f"full: {runs - n0} runs, {fails} failures")

# usage: repair takes exactly --keeper and --expect-sector (and --dry-run, --file); nothing else
hx = B0.hex()
for a, label in ((["repair", "--keeper", "a"], "no --expect-sector"),
                 (["repair", "--expect-sector", hx], "no --keeper"),
                 (["repair", "--keeper", "c", "--expect-sector", hx], "--keeper c"),
                 (["repair", "--keeper", "a", "--expect-sector", hx.upper()], "uppercase hex"),
                 (["repair", "--keeper", "a", "--expect-sector", hx[:-2]], "511 bytes"),
                 (["repair", "--keeper", "a", "--expect-sector", hx + "00"], "513 bytes"),
                 (["repair", "--keeper", "a", "--expect-sector", hx[:-1] + "g"], "not hex"),
                 (["repair", "--keeper", "a", "--expect-sector", hx, "--slot", "b"], "with --slot"),
                 (["repair", "--keeper", "a", "--expect-sector", hx, "--lower-keeper"], "with --lower-keeper"),
                 (["repair", "--keeper", "a", "--expect-sector", hx, "--expect", "a"], "with --expect"),
                 (["repair", "--keeper", "a", "--expect-sector", hx, "--token", "x"], "with --token"),
                 (["disable", "--slot", "b", "--keeper", "a"], "--keeper with disable"),
                 (["status", "--expect-sector", hx], "--expect-sector with status"),
                 (["arm-trying", "--slot", "b", "--lower-keeper", "--keeper", "a"], "--keeper with arm"),
                 (["switch", "--to", "a"], "switch without --expect-sector"),
                 (["switch", "--expect-sector", hx], "switch without --to"),
                 (["switch", "--to", "c", "--expect-sector", hx], "switch --to c"),
                 (["switch", "--to", "a", "--keeper", "a", "--expect-sector", hx], "switch with --keeper"),
                 (["switch", "--to", "a", "--slot", "a", "--expect-sector", hx], "switch with --slot"),
                 (["switch", "--to", "a", "--expect-sector", hx, "--lower-keeper"], "switch with --lower-keeper"),
                 (["repair", "--keeper", "a", "--to", "b", "--expect-sector", hx], "repair with --to"),
                 (["disable", "--slot", "b", "--to", "a"], "--to with disable"),
                 (["status", "--to", "a"], "--to with status")):
    rc, after, out, _ = run(BIN, B0, *a)
    runs += 1
    if rc != 1 or after != B0 or out:
        fail(f"usage {label}: want rc 1, untouched, no stdout; got rc {rc} out {out!r}")
print(f"usage cases: {fails} failures so far")

if OLD:
    # the commands of the reviewed binary: same rc, stdout and sector on every case
    cmds = [["status"], ["disable", "--slot", "a"], ["disable", "--slot", "b"],
            ["arm-trying", "--slot", "a"], ["arm-trying", "--slot", "b"],
            ["arm-trying", "--slot", "a", "--lower-keeper"], ["arm-trying", "--slot", "b", "--lower-keeper"],
            ["disable", "--slot", "b", "--dry-run"], ["arm-trying", "--slot", "b", "--lower-keeper", "--dry-run"],
            ["mark-successful", "--expect", "a"], ["mark-successful", "--expect", "b", "--dry-run"],
            ["bogus"], ["disable"], ["arm-trying", "--slot", "c"]]
    secs = list(cases.values())
    for i in range(SAMPLE):
        secs.append(mk([rnd.randrange(17), rnd.randrange(9), rnd.randrange(3), rnd.randrange(2)],
                       [rnd.randrange(17), rnd.randrange(9), rnd.randrange(3), rnd.randrange(2)]))
    if FULL:
        for a in range(0, 256, 3):
            for b in range(0, 256, 5):
                secs.append(mk([a >> 4, (a >> 1) & 7, a & 1, 0], [b >> 4, (b >> 1) & 7, b & 1, 0]))
    nd = 0
    for s in secs:
        for c in cmds:
            r1 = run(OLD, s, *c)
            r2 = run(BIN, s, *c)
            nd += 1
            if r1[:3] != r2[:3]:
                fail(f"differential {c} on {s[:32].hex()}: old rc {r1[0]} out {r1[2]!r}, new rc {r2[0]} out {r2[2]!r}")
            elif c[0] != "bogus" and c != ["disable"] and c != ["arm-trying", "--slot", "c"] and r1[3] != r2[3]:
                fail(f"differential {c} on {s[:32].hex()}: stderr differs:\n  old {r1[3]!r}\n  new {r2[3]!r}")
    print(f"differential: {nd} command runs on {len(secs)} sectors, {fails} failures")

print("\nRESULT:", "ALL PASS" if not fails else f"{fails} FAILURES", f"({runs} repair runs)")
sys.exit(1 if fails else 0)
