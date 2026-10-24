# rtl8363-init

This tool starts the RTL8364B Ethernet switch of the UC-P10 from user space.
The service `uc-pxx-switch` runs it before eth0 comes up.

The tool replays the init of the stock kernel: it starts the switch, sets the
external port 0 to RGMII with a fixed link of 1000 Mbit/s full duplex, sets
the RGMII delay and enables the PHYs. It talks to the switch through a sysfs
file of the kernel driver `ucp10-rtl8364b-smi` (default) or through MII
ioctls on an up interface (option `-m`).

## License

`main.c` and `smi_mdio.c` are GPL-2.0 (see the SPDX line in each file). They
link with the Realtek rtl8367c switch SDK, which is GPL-2.0. This repository
does not hold the SDK. `build.sh` says where to get it. The patch
`sdk-8364b-stock-sram.patch` changes one SDK file. It adds the PHY SRAM
patch that the stock kernel applies. The patch keeps the license of the SDK
file.

## Build

Run `SDK=DIR build.sh` on a build host. The result is a static aarch64
program. The package `uc-pxx-board` installs it as `/usr/sbin/rtl8363-init`.

## Open

Decide if the switch becomes a kernel driver. Then this tool goes away.
