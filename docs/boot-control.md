# A/B boot control

This page is a placeholder. The boot-control tool, the boot-marking hook and
the flash wrapper are not in this repository yet.

## What is missing

| Name | Task |
|---|---|
| `uc-pxx-bootctl` | Reads and writes the A/B metadata (AvbABData, `misc` LBA 49156) |
| `uc-pxx-mark-boot` | Marks the running slot as good after a healthy boot |
| `uc-pxx-flash-boot` | Sets the slot to "trying", writes `boot_a` and checks the data |
| `uc-pxx-update-boot` | Wraps `uc-pxx-flash-boot` for the package update |

The service `uc-pxx-boot-ok` is a stub. It calls `uc-pxx-mark-boot` when that
hook exists.

## Where the code comes from

The tools exist in the bring-up tree of the UC-P10 as `tools/p10-bootctl`.
They move here after a rename review. The tools change their name, so their
checksums change. A new review must pass before the renamed tools write the
metadata sector. Do not copy them before that review.

## Requirements

- The tool must keep at least one slot bootable at every step.
- The tool must write the CRC in the byte order that the metadata uses
  (big-endian).
- The tool must back up the sector and read it back after a write.
- The hook must refuse to mark a slot when the running system does not match
  the image in the slot. The build token in the image header and the file
  `/etc/uc-pxx-build-id` must be equal.
- The hook must not run while the flash wrapper runs.
- The hook must not mark a boot after a kernel oops.
- Phase 2 needs the tool for both slots. See [boot.md](boot.md).
