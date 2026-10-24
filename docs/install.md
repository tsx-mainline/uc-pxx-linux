# Install

This page is a placeholder. There is no installer in this repository yet.

## Plan

The install path starts from the stock Android userdebug system in slot B,
with root access over adb. It does these steps:

1. Check that the unit is a UC-P10 and that slot B is bootable.
2. Back up the partition table, the A/B metadata and the slot A partitions
   that the install changes.
3. Write `system_a` from the root file system image.
4. Create the LVM volume group `tsx` over `vendor_a` and `oem_a`, and the
   data volume in it.
5. Write `boot_a` through the flash wrapper, which sets slot A to "trying"
   first.
6. Reboot into slot A and wait for the boot to be marked as good.

Every step that writes the eMMC needs the rules of [boot.md](boot.md). The
install must stop before the first write when a check fails.

## TODO

- The installer script and its tests against a fake unit.
- The first-boot setup (root password or key, `panel.conf`).
- The path back to the stock slot A image.
- Phase 2: install on slot B.
