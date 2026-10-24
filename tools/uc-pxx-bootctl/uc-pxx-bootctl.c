/*
 * uc-pxx-bootctl — minimal, defensive AvbABData helper for the UC-P10 mainline image.
 *
 * mark-successful: what Android's boot_control markBootSuccessful() / libavb avb_ab_mark_slot_successful()
 *   does — on a healthy boot set the booted slot to successful (tries_remaining=0, successful_boot=1),
 *   priority untouched. Refuses unless the booted slot is the expected one AND currently bootable, and
 *   (with --token) unless boot_a holds the very image that is running (so a `fastboot boot` RAM boot can
 *   never bless whatever happens to be in boot_a).
 * arm-trying: re-arm slot A to "trying" {15,7,0} before flashing boot_a, so a bad new image runs down
 *   its tries and U-Boot falls back to slot B. Requires slot B successful (priority 1..14) and leaves it
 *   byte-identical.
 * Slot B's bytes are never modified by either command.
 *
 * AvbABData = first 32 bytes of eMMC LBA 49156 (misc partition start 49152 + 4):
 *   0..3 magic "\0AB0" | 4 version_major (1) | 5 version_minor | 6..7 reserved
 *   8..11 slot A {priority, tries_remaining, successful_boot, reserved}
 *   12..15 slot B {same}
 *   16..27 reserved | 28..31 crc32(bytes 0..27), stored BIG-endian
 * Bytes 32..511 of the sector are U-Boot leftovers and are written back unchanged.
 *
 * Usage:
 *   uc-pxx-bootctl status            [--file PATH]
 *   uc-pxx-bootctl mark-successful   --expect a|b [--token TOKEN] [--dry-run] [--file PATH]
 *   uc-pxx-bootctl arm-trying        --slot a [--dry-run] [--file PATH]
 * --file operates on a 512-byte sector image instead of the eMMC (testing; skips device checks;
 *   --token is then compared against the file given by --boot-file, default none = refuse).
 * Exit: 0 = done / nothing to do
 *       1 = refused, on-disk state unchanged
 *       2 = I/O error, but the on-disk sector was verified to be the original (unchanged or restored)
 *       3 = ON-DISK STATE UNKNOWN — do not reboot, inspect LBA 49156 by hand
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

#define EMMC_DEV     "/dev/mmcblk0"
#define EMMC_SYSFS   "/sys/class/block/mmcblk0"
#define MISC_SYSFS   EMMC_SYSFS "/mmcblk0p5"
#define BOOTA_SYSFS  EMMC_SYSFS "/mmcblk0p13"
#define BOOTA_DEV    "/dev/mmcblk0p13"
#define MISC_START   49152ULL
#define AB_LBA       49156ULL
#define SECTOR       512
#define TOKEN_OFF    48          /* Android boot image header v0: name[16] at offset 48 */
#define TOKEN_LEN    16

enum { RC_OK = 0, RC_REFUSED = 1, RC_IO_UNCHANGED = 2, RC_UNKNOWN = 3 };

static const char *file_path;  /* NULL = real eMMC */
static const char *boot_file;  /* test stand-in for boot_a when --file is used */

static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...)
{
	char buf[512];
	va_list ap;
	int fd;

	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	fprintf(stderr, "uc-pxx-bootctl: %s\n", buf);
	if (!file_path && (fd = open("/dev/kmsg", O_WRONLY)) >= 0) {
		dprintf(fd, "uc-pxx-bootctl: %s\n", buf);
		close(fd);
	}
}

static uint32_t crc32_ieee(const uint8_t *p, size_t n)
{
	uint32_t c = 0xffffffffu;

	for (size_t i = 0; i < n; i++) {
		c ^= p[i];
		for (int k = 0; k < 8; k++)
			c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1u)));
	}
	return ~c;
}

static uint32_t be32(const uint8_t *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static void put_be32(uint8_t *p, uint32_t v)
{
	p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

/* slot states libavb can hold: successful, trying, or unbootable (tries 0, not successful) */
static int slot_legal(const uint8_t *s)
{
	if (s[0] > 15 || s[1] > 7 || s[3] != 0)
		return 0;
	if (s[2] == 1)
		return s[1] == 0;          /* successful must have tries 0 (succ=1,tries>0 bricked a unit) */
	return s[2] == 0;              /* trying (tries>0) or unbootable (tries 0) */
}

/* libavb slot_is_bootable() */
static int slot_bootable(const uint8_t *s)
{
	return s[0] > 0 && (s[2] == 1 || s[1] > 0);
}

/* Full validation of a 32-byte AvbABData block. Returns NULL if OK, else a reason. */
static const char *validate(const uint8_t *ab)
{
	static const uint8_t magic[4] = { 0x00, 'A', 'B', '0' };

	if (memcmp(ab, magic, 4))
		return "bad magic";
	if (ab[4] != 1)
		return "unsupported version_major";
	if (ab[6] || ab[7])
		return "reserved bytes 6..7 not zero";
	for (int i = 16; i < 28; i++)
		if (ab[i])
			return "reserved bytes 16..27 not zero";
	if (be32(ab + 28) != crc32_ieee(ab, 28))
		return "crc32 mismatch (big-endian)";
	if (!slot_legal(ab + 8))
		return "slot A in illegal state";
	if (!slot_legal(ab + 12))
		return "slot B in illegal state";
	if (!slot_bootable(ab + 8) && !slot_bootable(ab + 12))
		return "no bootable slot";
	return NULL;
}

/* libavb avb_ab_flow slot choice: highest priority among BOOTABLE slots, slot A on a tie; -1 if none */
static int libavb_pick(const uint8_t *ab)
{
	int a = slot_bootable(ab + 8), b = slot_bootable(ab + 12);

	if (a && b)
		return ab[12] > ab[8] ? 1 : 0;
	return a ? 0 : b ? 1 : -1;
}

static int read_text(const char *path, char *out, size_t n)
{
	int fd = open(path, O_RDONLY);
	ssize_t r;

	if (fd < 0)
		return -1;
	r = read(fd, out, n - 1);
	close(fd);
	if (r < 0)
		return -1;
	out[r] = 0;
	return 0;
}

/* /dev/<node> must be the block device sysfs describes (major:minor) */
static int same_dev(const char *node, const char *sysfs_dir)
{
	char buf[64], path[256];
	unsigned maj, min;
	struct stat st;

	snprintf(path, sizeof(path), "%s/dev", sysfs_dir);
	if (read_text(path, buf, sizeof(buf)) || sscanf(buf, "%u:%u", &maj, &min) != 2)
		return 0;
	if (stat(node, &st) || !S_ISBLK(st.st_mode))
		return 0;
	return major(st.st_rdev) == maj && minor(st.st_rdev) == min;
}

/* /dev/mmcblk0 must be the eMMC whose p5 is "misc" at 49152 (and p13 "boot_a" when needed) */
static const char *check_device(int need_boota)
{
	char buf[256];

	if (read_text(EMMC_SYSFS "/device/type", buf, sizeof(buf)) || strncmp(buf, "MMC", 3))
		return "mmcblk0 is not an eMMC";
	if (read_text(EMMC_SYSFS "/queue/logical_block_size", buf, sizeof(buf)) || atoi(buf) != SECTOR)
		return "eMMC logical block size is not 512";
	if (read_text(MISC_SYSFS "/uevent", buf, sizeof(buf)) || !strstr(buf, "PARTNAME=misc\n"))
		return "mmcblk0p5 is not 'misc'";
	if (read_text(MISC_SYSFS "/start", buf, sizeof(buf)) || strtoull(buf, NULL, 10) != MISC_START)
		return "misc does not start at 49152";
	if (!same_dev(EMMC_DEV, EMMC_SYSFS))
		return EMMC_DEV " is not the device sysfs calls mmcblk0";
	if (need_boota) {
		if (read_text(BOOTA_SYSFS "/uevent", buf, sizeof(buf)) || !strstr(buf, "PARTNAME=boot_a\n"))
			return "mmcblk0p13 is not 'boot_a'";
		if (!same_dev(BOOTA_DEV, BOOTA_SYSFS))
			return BOOTA_DEV " is not the device sysfs calls mmcblk0p13";
	}
	return NULL;
}

static void *aligned_sector(void)
{
	void *buf;

	if (posix_memalign(&buf, 4096, 4096))
		return NULL;
	memset(buf, 0, 4096);
	return buf;
}

/* one O_DIRECT 512-byte read of the AB sector */
static int read_sector(uint8_t *out)
{
	const char *path = file_path ? file_path : EMMC_DEV;
	off_t off = file_path ? 0 : (off_t)(AB_LBA * SECTOR);
	void *buf = aligned_sector();
	int fd, ok;

	if (!buf)
		return -1;
	fd = open(path, O_RDONLY | (file_path ? 0 : O_DIRECT));
	if (fd < 0) {
		free(buf);
		return -1;
	}
	ok = pread(fd, buf, SECTOR, off) == SECTOR;
	close(fd);
	if (ok)
		memcpy(out, buf, SECTOR);
	free(buf);
	return ok ? 0 : -1;
}

/* read with retries; returns 0 and fills out on success */
static int read_sector_retry(uint8_t *out)
{
	const struct timespec ts = { 0, 100 * 1000 * 1000 };

	for (int i = 0; i < 5; i++) {
		if (!read_sector(out))
			return 0;
		nanosleep(&ts, NULL);
	}
	return -1;
}

/* one 512-byte O_DIRECT|O_DSYNC (FUA) write of exactly the AB sector, then fsync */
static int write_sector(const uint8_t *in)
{
	const char *path = file_path ? file_path : EMMC_DEV;
	off_t off = file_path ? 0 : (off_t)(AB_LBA * SECTOR);
	void *buf = aligned_sector();
	int fd, ok;

	if (!buf)
		return -1;
	memcpy(buf, in, SECTOR);
	fd = open(path, O_WRONLY | O_DSYNC | (file_path ? 0 : O_DIRECT));
	if (fd < 0) {
		free(buf);
		return -1;
	}
	ok = pwrite(fd, buf, SECTOR, off) == SECTOR;
	ok = (fsync(fd) == 0) && ok;
	close(fd);
	free(buf);
	return ok ? 0 : -1;
}

/*
 * Write `next` over `cur` and prove the result by read-back, whatever the write call returned.
 * Returns RC_OK (next on disk), RC_IO_UNCHANGED (cur on disk, unchanged or restored) or RC_UNKNOWN.
 */
static int commit(const uint8_t *cur, const uint8_t *next)
{
	uint8_t back[SECTOR];
	int wr = write_sector(next);

	if (wr)
		logmsg("write call failed: %s; checking what is on disk", strerror(errno));
	if (!read_sector_retry(back)) {
		if (!memcmp(back, next, SECTOR))
			return RC_OK;   /* the new sector is on disk and verified, whatever the write call said */
		if (!memcmp(back, cur, SECTOR)) {
			logmsg("write did not take; original sector still on disk (unchanged)");
			return RC_IO_UNCHANGED;
		}
	}
	logmsg("on-disk sector is neither old nor new (or unreadable); restoring the original");
	for (int i = 0; i < 3; i++) {
		write_sector(cur);
		if (!read_sector_retry(back) && !memcmp(back, cur, SECTOR)) {
			logmsg("original sector restored and verified");
			return RC_IO_UNCHANGED;
		}
	}
	logmsg("!!! ON-DISK A/B STATE UNKNOWN — DO NOT REBOOT — inspect LBA %llu by hand !!!", AB_LBA);
	return RC_UNKNOWN;
}

/* the running image's token must equal the name field of the boot_a header */
static int token_matches(const char *token)
{
	const char *path = boot_file ? boot_file : (file_path ? NULL : BOOTA_DEV);
	char want[TOKEN_LEN + 1] = { 0 }, have[TOKEN_LEN + 1] = { 0 };
	uint8_t hdr[64];
	int fd, ok;

	if (!path || strlen(token) == 0 || strlen(token) > TOKEN_LEN - 1)
		return 0;
	strncpy(want, token, TOKEN_LEN);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return 0;
	ok = pread(fd, hdr, sizeof(hdr), 0) == sizeof(hdr);
	close(fd);
	if (!ok || memcmp(hdr, "ANDROID!", 8))
		return 0;
	memcpy(have, hdr + TOKEN_OFF, TOKEN_LEN);
	have[TOKEN_LEN] = 0;
	return !strcmp(want, have);
}

static void describe(const char *tag, const uint8_t *ab)
{
	logmsg("%s: A{prio %u tries %u succ %u} B{prio %u tries %u succ %u} crc %08x",
	       tag, ab[8], ab[9], ab[10], ab[12], ab[13], ab[14], be32(ab + 28));
}

/* common post-checks: result validates and only the allowed bytes of the target slot changed */
static int only_target_changed(const uint8_t *cur, const uint8_t *next, int slot, int allow_prio)
{
	int base = 8 + 4 * slot;

	if (memcmp(next + 8 + 4 * !slot, cur + 8 + 4 * !slot, 4))
		return 0;
	for (int i = 0; i < SECTOR; i++) {
		int allowed = (i >= base + (allow_prio ? 0 : 1) && i <= base + 2) || (i >= 28 && i <= 31);

		if (next[i] != cur[i] && !allowed)
			return 0;
	}
	return 1;
}

static int usage(void)
{
	fprintf(stderr, "usage: uc-pxx-bootctl status | mark-successful --expect a|b [--token T] | "
		"arm-trying --slot a   [--dry-run] [--file PATH [--boot-file PATH]]\n");
	return RC_REFUSED;
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "", *token = NULL, *why;
	int expect = -1, arm_slot = -1, dry = 0, picked, mark, arm;
	uint8_t cur[SECTOR], next[SECTOR];

	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--dry-run"))
			dry = 1;
		else if (!strcmp(argv[i], "--file") && i + 1 < argc)
			file_path = argv[++i];
		else if (!strcmp(argv[i], "--boot-file") && i + 1 < argc)
			boot_file = argv[++i];
		else if (!strcmp(argv[i], "--token") && i + 1 < argc)
			token = argv[++i];
		else if (!strcmp(argv[i], "--expect") && i + 1 < argc) {
			i++;
			expect = !strcmp(argv[i], "a") ? 0 : !strcmp(argv[i], "b") ? 1 : -1;
		} else if (!strcmp(argv[i], "--slot") && i + 1 < argc) {
			i++;
			arm_slot = !strcmp(argv[i], "a") ? 0 : -1;
		} else
			return usage();
	}
	mark = !strcmp(cmd, "mark-successful");
	arm = !strcmp(cmd, "arm-trying");
	if (!mark && !arm && strcmp(cmd, "status"))
		return usage();

	if (!file_path && (why = check_device(mark && token))) {
		logmsg("refusing: %s", why);
		return RC_REFUSED;
	}
	if (read_sector_retry(cur)) {
		logmsg("read of LBA %llu failed: %s", AB_LBA, strerror(errno));
		return RC_REFUSED;
	}
	if ((why = validate(cur))) {
		logmsg("refusing: current AvbABData invalid: %s", why);
		return RC_REFUSED;
	}
	picked = libavb_pick(cur);
	describe("current", cur);

	if (!mark && !arm) {
		printf("libavb-would-boot: %c\n", picked < 0 ? '-' : "ab"[picked]);
		return RC_OK;
	}

	memcpy(next, cur, SECTOR);
	if (mark) {
		uint8_t *s = cur + 8 + 4 * expect;

		if (expect < 0) {
			logmsg("refusing: --expect a|b is required");
			return RC_REFUSED;
		}
		if (picked != expect) {
			logmsg("refusing: libavb would boot slot %c, expected %c",
			       picked < 0 ? '-' : "ab"[picked], "ab"[expect]);
			return RC_REFUSED;
		}
		if (!slot_bootable(s)) {
			logmsg("refusing: slot %c is not bootable", "ab"[expect]);
			return RC_REFUSED;
		}
		if (s[2] == 1) {
			logmsg("slot %c already successful, nothing to do", "ab"[expect]);
			return RC_OK;
		}
		if (token && !token_matches(token)) {
			logmsg("refusing: boot_a does not hold the running image (token %s); RAM boot?", token);
			return RC_REFUSED;
		}
		if (!token) {
			logmsg("refusing: --token is required to mark a slot successful");
			return RC_REFUSED;
		}
		next[8 + 4 * expect + 1] = 0;  /* tries_remaining */
		next[8 + 4 * expect + 2] = 1;  /* successful_boot */
	} else {
		const uint8_t *b = cur + 12;

		if (arm_slot != 0) {
			logmsg("refusing: only --slot a is supported");
			return RC_REFUSED;
		}
		if (!(b[2] == 1 && b[1] == 0 && b[0] >= 1 && b[0] <= 14)) {
			logmsg("refusing: slot B must be successful with priority 1..14 to stay the fallback");
			return RC_REFUSED;
		}
		if (cur[8] == 15 && cur[9] == 7 && cur[10] == 0) {
			logmsg("slot a already armed trying {15,7,0}, nothing to do");
			return RC_OK;
		}
		next[8] = 15;  /* priority above B so A is tried first */
		next[9] = 7;   /* tries_remaining */
		next[10] = 0;  /* successful_boot */
	}
	put_be32(next + 28, crc32_ieee(next, 28));

	/* belt and braces before touching the disk */
	if ((why = validate(next))) {
		logmsg("internal error, new state invalid: %s", why);
		return RC_REFUSED;
	}
	if (!only_target_changed(cur, next, mark ? expect : 0, arm)) {
		logmsg("internal error, a byte outside the target slot/crc would change");
		return RC_REFUSED;
	}
	if (!slot_bootable(next + 12) && !(mark && expect == 0 && slot_bootable(next + 8))) {
		logmsg("internal error, slot B would not stay bootable");
		return RC_REFUSED;
	}
	describe(dry ? "would write" : "writing", next);
	if (dry)
		return RC_OK;

	switch (commit(cur, next)) {
	case RC_OK:
		logmsg(mark ? "slot %c marked successful (verified by read-back)"
			    : "slot %c armed trying {15,7,0} (verified by read-back)", "ab"[mark ? expect : 0]);
		return RC_OK;
	case RC_IO_UNCHANGED:
		return RC_IO_UNCHANGED;
	default:
		return RC_UNKNOWN;
	}
}
