#!/bin/sh
# Host test for kernel/mkresource.py. It packs two small files and reads the
# image back with its own parser. It needs python3 only.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

printf 'first file' > "$T/a"
head -c 1000 /dev/zero | tr '\0' x > "$T/b"
python3 -I "$HERE/mkresource.py" "$T/out.img" rk-kernel.dtb="$T/a" logo.bmp="$T/b" > "$T/log" 2>&1 &&
	ok "mkresource.py runs" || bad "mkresource.py failed"

python3 -I - "$T/out.img" "$T/a" "$T/b" <<'PY' && ok "the image has the layout of an RSCE resource" || bad "wrong layout"
import struct, sys
img = open(sys.argv[1], "rb").read()
assert img[0:4] == b"RSCE", "magic"
count = struct.unpack_from("<I", img, 11)[0]
assert count == 2, "entry count %d" % count
want = {"rk-kernel.dtb": open(sys.argv[2], "rb").read(), "logo.bmp": open(sys.argv[3], "rb").read()}
for i in range(count):
    ent = img[512 * (1 + i):512 * (2 + i)]
    assert ent[0:4] == b"ENTR", "entry magic"
    name = ent[4:260].split(b"\0")[0].decode()
    off, size = struct.unpack_from("<II", ent, 260)
    assert img[512 * off:512 * off + size] == want[name], name
assert len(img) % 512 == 0, "size is not a multiple of 512"
PY

python3 -I "$HERE/mkresource.py" "$T/none.img" >/dev/null 2>&1 && bad "no arguments must fail" || ok "no file arguments: error"
echo "$N ok, $F failed"
[ "$F" = 0 ]
