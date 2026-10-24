#!/usr/bin/env python3
"""Test uc-pxx-bootctl against captured real AvbABData sectors (optional) plus synthetic bad cases.
Each output is checked independently here (not by the tool's own logic).
Usage: test.py <binary> [sector-dir...]
The folders hold files *.bin with a real sector at offset 0 or 2048. Without folders only the synthetic cases run.
Runs the binary directly; for aarch64 pass a qemu wrapper. Run heavy (qemu) runs on the build host."""
import binascii, glob, os, subprocess, sys, tempfile

BIN = sys.argv[1]
ROOTS = sys.argv[2:]
TOKEN = "ucpxx-abc123"


def crc_ok(b):
    return int.from_bytes(b[28:32], "big") == binascii.crc32(b[:28]) & 0xffffffff


def legal(s):
    p, t, ok, r = s
    if p > 15 or t > 7 or r:
        return False
    return t == 0 if ok == 1 else ok == 0


def bootable(s):
    return s[0] > 0 and (s[2] == 1 or s[1] > 0)


def valid(b):
    A, B = b[8:12], b[12:16]
    return (b[:4] == b"\0AB0" and b[4] == 1 and b[6:8] == b"\0\0" and b[16:28] == bytes(12)
            and crc_ok(b) and legal(A) and legal(B) and (bootable(A) or bootable(B)))


def pick(b):  # libavb: highest priority among bootable slots, A on tie
    a, bb = bootable(b[8:12]), bootable(b[12:16])
    if a and bb:
        return 1 if b[12] > b[8] else 0
    return 0 if a else 1 if bb else -1


def bootimg(name):
    h = bytearray(4096)
    h[:8] = b"ANDROID!"
    h[48:48 + len(name)] = name.encode()
    return bytes(h)


def run(sector, *args, boot=None):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "s.bin")
        open(p, "wb").write(sector)
        extra = []
        if boot is not None:
            bp = os.path.join(d, "boot.img")
            open(bp, "wb").write(boot)
            extra = ["--boot-file", bp]
        r = subprocess.run([BIN, *args, "--file", p, *extra], capture_output=True, text=True)
        return r.returncode, open(p, "rb").read(), r.stderr.strip()


def only_changed(before, after, allowed):
    return all(i in allowed for i in range(512) if before[i] != after[i])


def expect_mark(before, rc, after, token_ok=True):
    A = before[8:12]
    if not valid(before) or pick(before) != 0 or not bootable(A):
        return rc == 1 and after == before, "refuse, untouched (invalid / libavb would not boot A / A unbootable)"
    if A[2] == 1:
        return rc == 0 and after == before, "already successful: no change"
    if not token_ok:
        return rc == 1 and after == before, "token mismatch: refuse, untouched"
    good = (rc == 0 and valid(after) and after[8:12] == bytes([A[0], 0, 1, 0])
            and after[12:16] == before[12:16] and only_changed(before, after, (9, 10, 28, 29, 30, 31)))
    return good, "A->{prio,0,1,0}, B untouched, only bytes 9,10,28-31 changed"


def expect_arm(before, rc, after):
    B = before[12:16]
    if not valid(before) or not (B[2] == 1 and B[1] == 0 and 1 <= B[0] <= 14):
        return rc == 1 and after == before, "refuse, untouched (invalid / B not a successful fallback)"
    if before[8:11] == bytes([15, 7, 0]):
        return rc == 0 and after == before, "already armed: no change"
    good = (rc == 0 and valid(after) and after[8:12] == bytes([15, 7, 0, 0]) and after[12:16] == B
            and pick(after) == 0 and only_changed(before, after, (8, 9, 10, 28, 29, 30, 31)))
    return good, "A->{15,7,0}, B untouched, A boots next"


fails = 0
seen, files = set(), []
for r in ROOTS:
    for f in sorted(glob.glob(os.path.join(r, "**", "*.bin"), recursive=True)):
        d = open(f, "rb").read()
        for off in (0, 2048):
            s = d[off:off + 512]
            if len(s) == 512 and s[:4] == b"\0AB0" and s not in seen:
                seen.add(s)
                files.append((f + ("@2048" if off else ""), s))
print(f"{len(files)} distinct real sectors")


def check(name, s):
    global fails
    good_boot = bootimg(TOKEN)
    rc, after, err = run(s, "mark-successful", "--expect", "a", "--token", TOKEN, boot=good_boot)
    ok, rule = expect_mark(s, rc, after)
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'} mark  {name:38s} A{tuple(s[8:11])} B{tuple(s[12:15])} rc={rc} -> "
          f"A{tuple(after[8:11])} B{tuple(after[12:15])}  [{rule}]")
    if not ok:
        print("     stderr:", err)
    rc, after, err = run(s, "mark-successful", "--expect", "a", "--token", TOKEN, boot=bootimg("ucpxx-other"))
    ok, rule = expect_mark(s, rc, after, token_ok=False)
    fails += not ok
    if not ok:
        print(f"FAIL mark-wrong-token {name}: rc={rc} [{rule}] {err}")
    rc, after, err = run(s, "mark-successful", "--expect", "a", boot=good_boot)   # no --token
    ok = after == s and (rc == 1 or (rc == 0 and s[10] == 1 and valid(s) and pick(s) == 0))
    fails += not ok
    if not ok:
        print(f"FAIL mark-no-token {name}: rc={rc} {err}")
    rc, after, err = run(s, "arm-trying", "--slot", "a")
    ok, rule = expect_arm(s, rc, after)
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'} arm   {name:38s} A{tuple(s[8:11])} B{tuple(s[12:15])} rc={rc} -> "
          f"A{tuple(after[8:11])} B{tuple(after[12:15])}  [{rule}]")
    if not ok:
        print("     stderr:", err)
    for args in (["mark-successful", "--expect", "a", "--token", TOKEN, "--dry-run"],
                 ["arm-trying", "--slot", "a", "--dry-run"], ["status"]):
        rc, after, _ = run(s, *args, boot=good_boot)
        if after != s:
            print(f"FAIL {args[0]} dry-run/status modified {name}"); fails += 1


for f, s in files:
    check(os.path.basename(f), s)

base = next((s for f, s in files if s[8:12] == bytes([15, 7, 0, 0]) and s[12:16] == bytes([14, 0, 1, 0])), None)
if base is None:   # no captured sector given: build the A-trying {15,7,0} / B-successful {14,0,1} base
    base = bytearray(512)
    base[:4] = b"\0AB0"
    base[4] = 1
    base[8:12] = bytes([15, 7, 0, 0])
    base[12:16] = bytes([14, 0, 1, 0])
    base[28:32] = (binascii.crc32(bytes(base[:28])) & 0xffffffff).to_bytes(4, "big")
    base = bytes(base)


def mk(**slots):
    b = bytearray(base)
    for k, v in slots.items():
        o = 8 if k == "A" else 12 if k == "B" else int(k[1:])
        if isinstance(v, int):
            b[o] = v
        else:
            b[o:o + len(v)] = bytes(v)
    b[28:32] = (binascii.crc32(bytes(b[:28])) & 0xffffffff).to_bytes(4, "big")
    return bytes(b)


le = base[:28] + (binascii.crc32(base[:28]) & 0xffffffff).to_bytes(4, "little") + base[32:]
synth = {
    "LE crc": le,
    "bad magic": mk(o1=ord("X")),
    "version 2": mk(o4=2),
    "reserved 20 set": mk(o20=1),
    "A succ1 tries1 (brick state)": mk(A=[15, 1, 1, 0]),
    "B succ1 tries1 (brick state)": mk(B=[14, 1, 1, 0]),
    "B higher prio": mk(A=[14, 7, 0, 0], B=[15, 0, 1, 0]),
    "A prio 0 tries 3": mk(A=[0, 3, 0, 0]),
    "no bootable slot": mk(A=[15, 0, 0, 0], B=[14, 0, 0, 0]),
    "A tries 8": mk(A=[15, 8, 0, 0]),
    "A slot reserved byte": mk(A=[15, 7, 0, 1]),
    "tie 15/15 A trying": mk(B=[15, 0, 1, 0]),
    "A exhausted {15,0,0} (R1: refuse)": mk(A=[15, 0, 0, 0]),
    "A exhausted, tie B 15 succ (R1)": mk(A=[15, 0, 0, 0], B=[15, 0, 1, 0]),
    "A trying 5": mk(A=[15, 5, 0, 0]),
    "A trying 1": mk(A=[15, 1, 0, 0]),
    "A already successful": mk(A=[15, 0, 1, 0]),
    "A retired, B succ (arm ok)": mk(A=[0, 0, 0, 0]),
    "B trying (arm refuse)": mk(A=[15, 0, 1, 0], B=[14, 3, 0, 0]),
    "B prio 15 succ (arm refuse)": mk(A=[14, 0, 1, 0], B=[15, 0, 1, 0]),
    "B unbootable (arm refuse)": mk(A=[15, 0, 1, 0], B=[0, 0, 0, 0]),
}
for name, s in synth.items():
    check("synthetic: " + name, s)

for args, label in ((["mark-successful", "--expect", "b", "--token", TOKEN], "--expect b on A-trying"),
                    (["mark-successful", "--token", TOKEN], "missing --expect"),
                    (["arm-trying", "--slot", "b"], "arm --slot b"),
                    (["arm-trying"], "arm without --slot"),
                    (["bogus"], "unknown command")):
    rc, after, _ = run(base, *args, boot=bootimg(TOKEN))
    ok = rc == 1 and after == base
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'} refuse: {label}")

# token edge cases: not an Android image, token too long, empty token
for boot, tok, label in ((bytes(4096), TOKEN, "boot file not ANDROID!"),
                         (bootimg(TOKEN), "x" * 16, "token 16 chars (too long)"),
                         (bootimg(""), "", "empty token")):
    rc, after, _ = run(base, "mark-successful", "--expect", "a", "--token", tok, boot=boot)
    ok = rc == 1 and after == base
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'} token: {label}")

print("\nRESULT:", "ALL PASS" if not fails else f"{fails} FAILURES")
sys.exit(1 if fails else 0)
