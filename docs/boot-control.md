# A/B boot control

The panel has two boot slots, A and B. U-Boot reads the A/B metadata
(AvbABData) from the `misc` partition at LBA 49156 and starts the slot with
the highest priority that can boot. This page describes the tools that write
this sector.

Secure boot is on. If no slot can boot, no software can recover the panel.
At every step at least one slot must stay bootable.

## The tools

| Name | Place on the panel | Task |
|---|---|---|
| `uc-pxx-bootctl` | `/usr/sbin/uc-pxx-bootctl` | Static aarch64 program. Reads and writes the A/B metadata |
| `uc-pxx-mark-boot` | `/etc/uc-pxx-mark-boot.sh` | Marks slot A as good after a healthy boot |
| `uc-pxx-flash-boot` | `/usr/sbin/uc-pxx-flash-boot` | Sets slot A to "trying", writes `boot_a` and checks the data |
| `uc-pxx-arm-slot` | `/usr/sbin/uc-pxx-arm-slot` | Sets slot A to "trying" before an update changes `system_a` or `boot_a` |
| `uc-pxx-update-boot` | | Wraps `uc-pxx-flash-boot` for the package update. Not written yet |

The service `uc-pxx-boot-ok` starts `uc-pxx-mark-boot` in the background.
The sources are in this repository:
`tools/uc-pxx-bootctl/uc-pxx-bootctl.c`,
`rootfs/overlay/etc/uc-pxx-mark-boot.sh`,
`rootfs/overlay/usr/sbin/uc-pxx-flash-boot` and
`rootfs/overlay/usr/sbin/uc-pxx-arm-slot`. The binary is not in the
repository. Build it with `tools/uc-pxx-bootctl/build.sh` (see "Build and
test"). The package `uc-pxx-boot-tools` must install it.

### uc-pxx-bootctl

```
uc-pxx-bootctl status
uc-pxx-bootctl mark-successful --expect a --token TOKEN
uc-pxx-bootctl arm-trying --slot a
```

- `status` prints the state of both slots and changes nothing.
- `mark-successful` sets the booted slot to "successful" (tries 0,
  successful 1). It refuses unless the booted slot is the expected slot and
  can boot. With `--token` it also refuses unless the build token in the
  header of `boot_a` equals the token. So a RAM boot never marks the image
  that is in `boot_a`.
- `arm-trying` sets slot A to "trying" (priority 15, tries 7, successful 0).
  It requires slot B to be "successful" with priority 1 to 14.
- No command changes the bytes of slot B.
- Every write checks the metadata first (magic, version, reserved bytes,
  big-endian CRC, legal slot states, at least one slot bootable). The tool
  keeps a copy of the sector and reads it back after the write.
- Exit status: 0 done or nothing to do. 1 refused, the sector is unchanged.
  2 I/O error, the original sector was verified. 3 state unknown.
- `--dry-run` and `--file PATH` (a 512-byte sector image) are for tests.

### uc-pxx-mark-boot

The hook marks slot A as good when the boot is healthy. It runs these steps
in this order and stops at the first one that fails:

1. Stop when the kernel command line has `uc-pxx.nomark` or the file
   `/etc/uc-pxx-nomark` exists.
2. Read the build token from the word `uc-pxx.id=TOKEN` on the kernel
   command line. Stop when it is missing. The hook never reads the token
   from a file, because the root file system (`system_a`) is not part of the
   running image. `kernel/mkimage.sh` writes the same token to the name field
   of the `boot_a` header and to `/chosen/bootargs` of the embedded device
   tree. `uc-pxx-bootctl` compares the token with the header.
3. Wait until the uptime is 60 seconds.
4. Wait up to 300 seconds for an IPv4 address on `eth0` (or a configured USB
   link on `usb0`) and a running `sshd`.
5. Stop when the kernel has an oops (taint bit 7).
6. Take the lock `/run/uc-pxx-abdata.lock` without waiting. Stop when the
   flash wrapper or `uc-pxx-arm-slot` holds it, or when
   `/run/uc-pxx-slot-a-changed` exists.
7. Run `uc-pxx-bootctl mark-successful --expect a --token <build token>`.
   On exit status 3 the hook lights the red status LED.

A boot that the hook does not mark stays "trying". It uses up its tries, and
U-Boot starts the other slot.

### uc-pxx-flash-boot

```
uc-pxx-flash-boot IMAGE SHA256
```

The wrapper checks the image (Android boot image, at most 64 MiB, a build
token in the header, the given checksum). It takes the lock
`/run/uc-pxx-abdata.lock` (it polls for up to 600 seconds) and creates
`/run/uc-pxx-slot-a-changed`. It then arms slot A to "trying" and checks
the exact state. Only after that it writes `boot_a`, reads the data back and
compares the checksum. At the end it arms slot A to "trying" again. A bad new
image uses up its tries, and U-Boot falls back to slot B.

### uc-pxx-arm-slot

```
uc-pxx-arm-slot
```

The helper takes the lock `/run/uc-pxx-abdata.lock` (it polls for up to 600
seconds), creates `/run/uc-pxx-slot-a-changed`, arms slot A to "trying" and
checks that the state is exactly priority 15, tries 7, successful 0. Exit
status 0 means armed. Exit status 1 means the call failed, and the caller
must not change `system_a` or `boot_a`. Exit status 3 means the state is
unknown: the script lights the red status LED, and nobody may reboot.

The marker stays until the next boot. The hook of this boot never marks
slot A again. The next boot marks A when it is healthy, because the token has
not changed when only `system_a` changed.

## The update rule

While slot A is "successful", a bad change to `system_a` has no automatic
fallback to slot B. This holds for a new `init`, `openrc`, `sshd` or hook
from `apk upgrade`, and for a rewrite of `system_a`. So every program that
changes `system_a` or `boot_a` must call `uc-pxx-arm-slot` first and must stop
when it fails:

- `tsx-autoupdate`, through the board hook `tsx_board_pre_update` in
  `board.sh`. The hook runs `uc-pxx-arm-slot`. `tsx-autoupdate` runs it after
  the check found packages and before `apk upgrade`. If the hook exits with a
  non-zero status, `tsx-autoupdate` does not install. It logs the status and
  keeps the packages pending. A check alone never calls the hook
- the post-install script of the kernel package
- the installer
- `uc-pxx-update-boot`

The installer runs on Android in slot B, where the eMMC has another device
name. `uc-pxx-bootctl` uses `/dev/mmcblk0`, so it does not work there. The
installer needs its own reviewed way to arm slot A.

## The flash rule

Write `boot_a` only with `uc-pxx-flash-boot`. A plain `dd` to `boot_a` while
slot A is "successful" removes the automatic fallback to slot B. If you must
write `boot_a` in another way, arm slot A to "trying" first.

Do not write the A/B metadata, the idbloader, the GPT, `uboot_*`, `trust_*`
or `vbmeta_*` in any other way. The tools above are the only reviewed ways
to write sector 49156.

## Off switches

| Switch | Effect |
|---|---|
| `uc-pxx.nomark` on the kernel command line | The hook does not mark the boot. The slot stays as it is |
| The file `/etc/uc-pxx-nomark` | The same, for development and test images |
| A missing `uc-pxx.id=` word on the kernel command line | The hook does not mark the boot |
| The marker `/run/uc-pxx-slot-a-changed` | The hook does not mark the boot (set by the flash wrapper and `uc-pxx-arm-slot`) |
| `rc-update del uc-pxx-boot-ok default` | The service does not start |

Use a switch on every image that does not come from the image builder.

## Build and test

Build and test on a build host that has `aarch64-linux-gnu-gcc` and
`qemu-aarch64-static`. Do not build on a workstation.

```
tools/uc-pxx-bootctl/build.sh [OUT]
```

The script builds with `-O2 -Wall -Wextra -Werror -static` and runs
`tools/uc-pxx-bootctl/test.py` under qemu. The test checks the output of the
tool with its own code, not with the logic of the tool. It uses synthetic
sectors (bad CRC byte order, illegal slot states, no bootable slot, token
cases). Give captured real sectors with `SECTORS=DIR` (files `*.bin`).

Two more tests use the binary. `kernel/tests/test-mkimage.sh` checks that the
embedded device tree has the token and that the header name equals it.
`rootfs/tests/test-mark-boot.sh` runs the hook and `uc-pxx-arm-slot` on a
sector file. Give it a program that runs on the host:

```
UC_PXX_BOOTCTL_RUN="qemu-aarch64-static ./uc-pxx-bootctl-aarch64" sh rootfs/tests/test-mark-boot.sh
```

## Review

The binary and the two scripts were reviewed under their old names
(`p10-*`). The renamed files differ in names and strings, in the process name
`sshd` (the image uses OpenSSH, not dropbear), in the source of the token (the
kernel command line), and in the marker `/run/uc-pxx-slot-a-changed`. The
helper `uc-pxx-arm-slot` is new. The files need a review of their exact
checksums before they write the metadata sector on a panel.

## Requirements

- The tool must keep at least one slot bootable at every step.
- The tool must write the CRC in the byte order that the metadata uses
  (big-endian).
- The tool must back up the sector and read it back after a write.
- The hook must refuse to mark a slot when the running kernel does not match
  the image in the slot. It takes the token from the kernel command line only.
- Every change to `system_a` or `boot_a` must arm slot A first.
- The hook must not run while the flash wrapper runs.
- The hook must not mark a boot after a kernel oops.
- Phase 2 needs the tool for both slots. See [boot.md](boot.md).
