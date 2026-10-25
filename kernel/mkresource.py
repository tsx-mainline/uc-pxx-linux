#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Pack files into a Rockchip resource image (RSCE).

U-Boot reads this image from the "second" area of the Android boot image.
It takes its device tree from the entry rk-kernel.dtb.

Usage: mkresource.py OUT.img NAME=PATH [NAME=PATH ...]
Example: mkresource.py resource.img rk-kernel.dtb=u-boot-tree.dtb

The device tree for U-Boot must come from the vendor tree of the unit and
must have no PMIC nodes (docs/boot.md "The boot image"). This repository
holds no such file. Give your own.

Layout, as in the Rockchip struct resource_img_hdr:
  header block (512 bytes): "RSCE", u16 version, u16 index version,
      u8 header blocks, u8 table offset blocks, u8 entry blocks, one pad byte,
      u32 entry count (at byte 12)
  one 512 byte entry for each file: "ENTR", name (256 bytes), u32 offset
      (in 512 byte blocks from the start of the image), u32 size
  the file data, each file padded to 512 bytes
"""
import os
import struct
import sys

BLOCK = 512
NAME_MAX = 256


def build(items):
    """Return the image bytes for a list of (name, data) pairs."""
    hdr = bytearray(BLOCK)
    hdr[0:4] = b"RSCE"
    struct.pack_into("<HHBBB", hdr, 4, 0, 0, 1, 1, 1)
    struct.pack_into("<I", hdr, 12, len(items))
    entries = bytearray()
    data = bytearray()
    off = 1 + len(items)
    for name, blob in items:
        raw = name.encode()
        if not raw or len(raw) >= NAME_MAX:
            raise ValueError("bad entry name: %r" % name)
        ent = bytearray(BLOCK)
        ent[0:4] = b"ENTR"
        ent[4:4 + len(raw)] = raw
        struct.pack_into("<II", ent, 4 + NAME_MAX, off, len(blob))
        entries += ent
        pad = (-len(blob)) % BLOCK
        data += blob + b"\0" * pad
        off += (len(blob) + pad) // BLOCK
    return bytes(hdr) + bytes(entries) + bytes(data)


def main(argv):
    if len(argv) < 3 or any("=" not in a for a in argv[2:]):
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 2
    items = []
    for arg in argv[2:]:
        name, path = arg.split("=", 1)
        with open(path, "rb") as f:
            items.append((name, f.read()))
        print("%s: %d bytes" % (name, len(items[-1][1])))
    img = build(items)
    with open(argv[1], "wb") as f:
        f.write(img)
    print("wrote %s, %d bytes" % (argv[1], os.path.getsize(argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
