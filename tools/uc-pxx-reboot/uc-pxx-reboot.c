// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * uc-pxx-reboot: restart the unit with a reboot command argument.
 *
 *   uc-pxx-reboot [--dry-run] loader
 *
 * The busybox reboot has no argument. This program calls reboot(2) with
 * LINUX_REBOOT_CMD_RESTART2 and the argument "loader". The device tree node
 * reboot-mode (syscon-reboot-mode on the PMU GRF) turns it into the magic
 * value BOOT_BL_DOWNLOAD in PMUGRF_OS_REG0. The vendor U-Boot then enters the
 * download mode (rockusb). The program writes nothing to the eMMC. A power
 * cycle leaves the download mode.
 *
 * Only the argument "loader" is allowed. --dry-run prints what it would do
 * and exits with 0 (for tests).
 */
#include <linux/reboot.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	int dry = argc == 3 && !strcmp(argv[1], "--dry-run");
	const char *arg = argc == 2 ? argv[1] : dry ? argv[2] : NULL;

	if (!arg || strcmp(arg, "loader")) {
		fprintf(stderr, "usage: uc-pxx-reboot [--dry-run] loader\n");
		return 2;
	}
	if (dry) {
		printf("would reboot with the argument '%s'\n", arg);
		return 0;
	}
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, arg);
	perror("uc-pxx-reboot: reboot");
	return 1;
}
