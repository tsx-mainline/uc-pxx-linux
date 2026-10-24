// SPDX-License-Identifier: GPL-2.0
/*
 * rtl8363-init: bring up the UC-P10's on-board Realtek RTL8364B/RTL8363SC switch
 * (RGMII uplink to the RK3399 GMAC) from userspace under mainline Linux.
 *
 * Replays the stock Grandstream kernel's switch init (stock 4.4.167 Image+0x517e9c):
 *   rtk_switch_init();
 *   rtk_port_macForceLinkExt_set(EXT_PORT0, MODE_EXT_RGMII,
 *                                {force, 1000M, full, link, nway=0, txpause, rxpause});
 *   rtk_port_rgmiiDelayExt_set(EXT_PORT0, 1, 0);
 *   rtk_port_phyEnableAll_set(ENABLED);
 *
 * Default back-end: sysfs file of the realtek-rtl8364b-smi kernel driver; run this
 * while eth0 is still DOWN (the MAC DMA reset needs the switch's RGMII clock).
 * -m: use MII ioctls on an UP eth0 with an attached PHY instead.
 *
 * usage: rtl8363-init [-m] [-i IF] [-v] probe|init [TXDLY RXDLY]|status|r REG|w REG VAL
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "rtk_types.h"
#include "rtk_error.h"
#include "rtk_switch.h"
#include "port.h"
#include "rtl8367c_asicdrv.h"
#include "smi.h"

int smi_open(const char *ifname, int use_ioctl);
extern int smi_verbose;
extern unsigned long smi_ops;

static const char *chip_name(switch_chip_t c)
{
	switch (c) {
	case CHIP_RTL8367C: return "RTL8367C";
	case CHIP_RTL8370B: return "RTL8370B";
	case CHIP_RTL8364B: return "RTL8364B";
	case CHIP_RTL8363SC_VB: return "RTL8363SC_VB";
	default: return "unknown";
	}
}

static int do_probe(void)
{
	rtk_uint32 id = 0, ver = 0;
	switch_chip_t chip;
	rtk_api_ret_t r;

	if (rtl8367c_setAsicReg(0x13C2, 0x0249) || rtl8367c_getAsicReg(0x1300, &id) ||
	    rtl8367c_getAsicReg(0x1301, &ver) || rtl8367c_setAsicReg(0x13C2, 0x0000)) {
		printf("rtl8363: SMI access failed\n");
		return 1;
	}
	r = rtk_switch_probe(&chip);
	printf("rtl8363: chip id 0x%04x ver 0x%04x -> %s (probe ret %d)\n", id, ver,
	       r == RT_ERR_OK ? chip_name(chip) : "NOT SUPPORTED", (int)r);
	return r != RT_ERR_OK;
}

static void do_status(void)
{
	static const rtk_port_t utp[] = { UTP_PORT1, UTP_PORT3 };
	static const char *spd[] = { "10M", "100M", "1000M", "500M", "2500M" };
	rtk_port_mac_ability_t st;
	rtk_data_t tx = 0, rx = 0;
	unsigned int i;

	for (i = 0; i < 2; i++) {
		rtk_port_linkStatus_t l = 0;
		rtk_port_speed_t s = 0;
		rtk_port_duplex_t d = 0;

		if (rtk_port_phyStatus_get(utp[i], &l, &s, &d) == RT_ERR_OK)
			printf("rtl8363: port %u (%s): link %s %s %s\n", (unsigned)utp[i],
			       utp[i] == UTP_PORT3 ? "LAN" : "PC", l ? "UP" : "down",
			       l ? (s < 5 ? spd[s] : "?") : "", l ? (d ? "full" : "half") : "");
		else
			printf("rtl8363: port %u: phyStatus read failed\n", (unsigned)utp[i]);
	}
	memset(&st, 0, sizeof(st));
	if (rtk_port_macStatus_get(EXT_PORT0, &st) == RT_ERR_OK)
		printf("rtl8363: EXT_PORT0 (RGMII to SoC): link %u speed %u duplex %u txp %u rxp %u\n",
		       st.link, st.speed, st.duplex, st.txpause, st.rxpause);
	if (rtk_port_rgmiiDelayExt_get(EXT_PORT0, &tx, &rx) == RT_ERR_OK)
		printf("rtl8363: EXT_PORT0 RGMII delay tx %u rx %u\n", tx, rx);
}

static int do_init(rtk_data_t txd, rtk_data_t rxd)
{
	rtk_port_mac_ability_t mac;
	rtk_api_ret_t r;

	r = rtk_switch_init();
	printf("rtl8363: rtk_switch_init -> %d (%lu SMI ops)\n", (int)r, smi_ops);
	if (r != RT_ERR_OK)
		return 1;

	memset(&mac, 0, sizeof(mac));
	mac.forcemode = 1;
	mac.speed = PORT_SPEED_1000M;
	mac.duplex = PORT_FULL_DUPLEX;
	mac.link = 1;
	mac.nway = 0;
	mac.txpause = 1;
	mac.rxpause = 1;
	r = rtk_port_macForceLinkExt_set(EXT_PORT0, MODE_EXT_RGMII, &mac);
	printf("rtl8363: macForceLinkExt(EXT_PORT0, RGMII, 1000F) -> %d\n", (int)r);
	if (r != RT_ERR_OK)
		return 1;
	r = rtk_port_rgmiiDelayExt_set(EXT_PORT0, txd, rxd);
	printf("rtl8363: rgmiiDelayExt(EXT_PORT0, tx %u, rx %u) -> %d\n", txd, rxd, (int)r);
	if (r != RT_ERR_OK)
		return 1;
	r = rtk_port_phyEnableAll_set(ENABLED);
	printf("rtl8363: phyEnableAll -> %d (%lu SMI ops total)\n", (int)r, smi_ops);
	return r != RT_ERR_OK;
}

int main(int argc, char **argv)
{
	const char *ifname = "eth0";
	unsigned long a, b;
	int c, ret, use_ioctl = 0;

	while ((c = getopt(argc, argv, "mi:v")) != -1) {
		if (c == 'm')
			use_ioctl = 1;
		else if (c == 'i')
			ifname = optarg;
		else if (c == 'v')
			smi_verbose++;
		else
			goto usage;
	}
	if (optind >= argc)
		goto usage;
	if (smi_open(ifname, use_ioctl)) {
		fprintf(stderr, "rtl8363: no SMI access path\n");
		return 1;
	}

	if (!strcmp(argv[optind], "probe"))
		return do_probe();
	if (!strcmp(argv[optind], "status")) {
		if (do_probe())
			return 1;
		/*
		 * A fresh process has the SDK's in-memory init flag clear, so every
		 * rtk_port_* getter would return RT_ERR_NOT_INIT ("phyStatus read
		 * failed"). The switch itself was initialised by "init"; only mark
		 * the SDK state (no register writes here).
		 */
		rtk_switch_initialState_set(INIT_COMPLETED);
		do_status();
		return 0;
	}
	if (!strcmp(argv[optind], "init")) {
		rtk_data_t txd = 1, rxd = 0;	/* stock values */

		if (optind + 2 < argc) {
			txd = strtoul(argv[optind + 1], NULL, 0);
			rxd = strtoul(argv[optind + 2], NULL, 0);
		}
		if (do_probe())
			return 1;
		ret = do_init(txd, rxd);
		do_status();
		return ret;
	}
	if (!strcmp(argv[optind], "r") && optind + 1 < argc) {
		rtk_uint32 v = 0;

		a = strtoul(argv[optind + 1], NULL, 0);
		if (smi_read(a, &v) != RT_ERR_OK)
			return 1;
		printf("0x%04lx = 0x%04x\n", a, v);
		return 0;
	}
	if (!strcmp(argv[optind], "w") && optind + 2 < argc) {
		a = strtoul(argv[optind + 1], NULL, 0);
		b = strtoul(argv[optind + 2], NULL, 0);
		return smi_write(a, b) != RT_ERR_OK;
	}
usage:
	fprintf(stderr, "usage: %s [-m] [-i IF] [-v] probe|init [TXDLY RXDLY]|status|r REG|w REG VAL\n",
		argv[0]);
	return 2;
}
