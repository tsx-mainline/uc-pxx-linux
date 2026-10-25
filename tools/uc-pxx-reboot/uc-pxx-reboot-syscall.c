// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * uc-pxx-reboot-syscall: restart the unit at once with a reboot command
 * argument.
 *
 *   uc-pxx-reboot-syscall [--dry-run] loader|fastboot
 *
 * This is the last step of uc-pxx-reboot (rootfs/overlay/usr/sbin). Do not
 * run it by hand on a running system: it stops no service and unmounts
 * nothing. uc-pxx-reboot lets init stop the system first.
 *
 * The busybox reboot has no argument. This program calls sync(2) and then
 * reboot(2) with LINUX_REBOOT_CMD_RESTART2 and the argument. The device tree
 * node reboot-mode (syscon-reboot-mode on the PMU GRF) turns the argument
 * into a magic value in PMUGRF_OS_REG0: "loader" is BOOT_BL_DOWNLOAD (the
 * download mode, rockusb), "fastboot" is BOOT_FASTBOOT. The vendor U-Boot
 * reads the value at the next start. The program writes nothing to the eMMC.
 *
 * Only the arguments "loader" and "fastboot" are allowed. --dry-run prints
 * what it would do and exits with 0 (for tests).
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

	if (!arg || (strcmp(arg, "loader") && strcmp(arg, "fastboot"))) {
		fprintf(stderr, "usage: uc-pxx-reboot-syscall [--dry-run] loader|fastboot\n");
		return 2;
	}
	if (dry) {
		printf("would reboot with the argument '%s'\n", arg);
		return 0;
	}
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, arg);
	perror("uc-pxx-reboot-syscall: reboot");
	return 1;
}
