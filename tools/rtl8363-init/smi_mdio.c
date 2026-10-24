// SPDX-License-Identifier: GPL-2.0
/*
 * UC-P10: Realtek rtl8367c-SDK SMI back-end (replaces the SDK's smi.c).
 *
 * The stock Grandstream kernel reaches the on-board RTL8364B switch through the
 * RK3399 GMAC MDIO bus, using the Realtek "MDC/MDIO" indirect protocol at MDIO
 * address 29 (decoded from the stock 4.4.167 kernel, Image+0x532838/+0x532908):
 *   write: w(29,31,0x000E) w(29,23,reg) w(29,24,val) w(29,21,0x0003)
 *   read:  w(29,31,0x000E) w(29,23,reg) w(29,21,0x0001) r(29,25)
 *
 * Back-ends:
 *  1. sysfs (default): the kernel driver ucp10-rtl8364b-smi does the protocol;
 *     file .../<mdio dev>/smi: write "reg" + read -> value, write "reg val".
 *     Works while eth0 is DOWN, which is required: the MAC DMA reset on
 *     "ip link set eth0 up" needs the RGMII RX clock from the switch.
 *  2. MII ioctls on an UP eth0 with an attached PHY (fallback, -m).
 */
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <linux/mii.h>
#include <linux/sockios.h>

#include "rtk_types.h"
#include "rtk_error.h"
#include "smi.h"

#define SW_MDIO_ADDR	29
#define SYSFS_GLOB	"/sys/bus/mdio_bus/drivers/ucp10-rtl8364b-smi/*/smi"

static int smi_fd = -1;		/* sysfs file */
static int sock_fd = -1;	/* ioctl back-end */
static char smi_ifname[IFNAMSIZ] = "eth0";
int smi_verbose;
unsigned long smi_ops;

/* use_ioctl: 0 = sysfs only, 1 = ioctl only */
int smi_open(const char *ifname, int use_ioctl)
{
	glob_t g;

	if (ifname)
		snprintf(smi_ifname, sizeof(smi_ifname), "%s", ifname);
	if (use_ioctl) {
		sock_fd = socket(AF_INET, SOCK_DGRAM, 0);
		return sock_fd < 0 ? -errno : 0;
	}
	if (glob(SYSFS_GLOB, 0, NULL, &g) == 0 && g.gl_pathc > 0) {
		smi_fd = open(g.gl_pathv[0], O_RDWR);
		if (smi_verbose && smi_fd >= 0)
			fprintf(stderr, "smi: using %s\n", g.gl_pathv[0]);
		globfree(&g);
		return smi_fd < 0 ? -errno : 0;
	}
	fprintf(stderr, "smi: %s not found (driver ucp10-rtl8364b-smi not bound?)\n", SYSFS_GLOB);
	return -ENOENT;
}

static int mdio_rw(int write, unsigned int reg, unsigned int *val)
{
	struct ifreq ifr;
	struct mii_ioctl_data *mii = (struct mii_ioctl_data *)&ifr.ifr_data;

	memset(&ifr, 0, sizeof(ifr));
	snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", smi_ifname);
	mii->phy_id = SW_MDIO_ADDR;
	mii->reg_num = reg;
	mii->val_in = write ? *val : 0;
	if (ioctl(sock_fd, write ? SIOCSMIIREG : SIOCGMIIREG, &ifr) < 0) {
		if (smi_verbose)
			fprintf(stderr, "mdio %s reg %u: %s\n", write ? "write" : "read",
				reg, strerror(errno));
		return -1;
	}
	if (!write)
		*val = mii->val_out;
	return 0;
}

static int mdio_w(unsigned int reg, unsigned int v)
{
	return mdio_rw(1, reg, &v);
}

static int sysfs_cmd(const char *s)
{
	ssize_t n = pwrite(smi_fd, s, strlen(s), 0);

	if (n != (ssize_t)strlen(s)) {
		if (smi_verbose)
			fprintf(stderr, "smi: write '%s': %s\n", s, strerror(errno));
		return -1;
	}
	return 0;
}

rtk_int32 smi_write(rtk_uint32 mAddrs, rtk_uint32 rData)
{
	char b[32];

	if (mAddrs > 0xFFFF || rData > 0xFFFF)
		return RT_ERR_INPUT;
	smi_ops++;
	if (smi_fd >= 0) {
		snprintf(b, sizeof(b), "0x%x 0x%x", mAddrs, rData);
		if (sysfs_cmd(b))
			return RT_ERR_FAILED;
	} else if (sock_fd >= 0) {
		if (mdio_w(31, 0x000E) || mdio_w(23, mAddrs) || mdio_w(24, rData) ||
		    mdio_w(21, 0x0003))
			return RT_ERR_FAILED;
	} else {
		return RT_ERR_NULL_POINTER;
	}
	if (smi_verbose > 1)
		fprintf(stderr, "  W %04x = %04x\n", mAddrs, rData);
	return RT_ERR_OK;
}

rtk_int32 smi_read(rtk_uint32 mAddrs, rtk_uint32 *rData)
{
	unsigned int v = 0;
	char b[32];

	if (mAddrs > 0xFFFF)
		return RT_ERR_INPUT;
	if (!rData)
		return RT_ERR_NULL_POINTER;
	smi_ops++;
	if (smi_fd >= 0) {
		ssize_t n;

		snprintf(b, sizeof(b), "0x%x", mAddrs);
		if (sysfs_cmd(b))
			return RT_ERR_FAILED;
		n = pread(smi_fd, b, sizeof(b) - 1, 0);
		if (n <= 0)
			return RT_ERR_FAILED;
		b[n] = 0;
		v = strtoul(b, NULL, 0);
	} else if (sock_fd >= 0) {
		if (mdio_w(31, 0x000E) || mdio_w(23, mAddrs) || mdio_w(21, 0x0001) ||
		    mdio_rw(0, 25, &v))
			return RT_ERR_FAILED;
	} else {
		return RT_ERR_NULL_POINTER;
	}
	*rData = v & 0xFFFF;
	if (smi_verbose > 1)
		fprintf(stderr, "  R %04x -> %04x\n", mAddrs, *rData);
	return RT_ERR_OK;
}
