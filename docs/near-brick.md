# The near-brick: two drivers the board needed

The first kernel trim turned off every SPI and PHY/switch driver that looked unused. Two of them were not:

- `CONFIG_SPI_AR934X`. The AR9330 device tree (`ar9330.dtsi`) says its SPI controller is `qca,ar934x-spi`. The driver I kept, `spi-ath79`, only matches `qca,ar7100-spi`. No flash driver means no MTD, no rootfs, a kernel panic, and with `PANIC_TIMEOUT=1` a reboot loop.
- `CONFIG_AR8216_PHY`. The built-in switch is `qca,ar7240sw`, and only `ar8216.c` drives it. eth0's `phy-handle` points to a PHY on that switch's MDIO bus. Without it, no Ethernet.

QEMU could not catch this, because it does not emulate this SoC. A review pass before the flash did. Putting both back cost 8,480 bytes of kernel. `build/kernel-trim.config` now says so at the top.

## The check

`tools/dtbcheck.py` does the same review mechanically:

```sh
tools/dtbcheck.py build/src/bin/targets/ath79/tiny/*-sysupgrade.bin /tmp/dtb \
  $(find build/src/build_dir/target-mips_24kc_musl/linux-ath79_tiny -name '*.ko')
```

It unpacks the LZMA kernel from the TP-Link image, finds the appended device tree (`d00dfeed`), decompiles it with `dtc`, and for each node prints whether each `compatible` string appears in vmlinux (outside the DTB) or in one of the given modules. A string that is in the binary does not prove the driver binds, but a string that is nowhere proves it cannot.

On the final image the only enabled nodes without a match are the board root, the CPU, the DDR controller (used through a phandle by the interrupt code, no driver binds to it) and the USB nodes, which are disabled in the device tree.

Run it after every kernel config change. It catches missing drivers. It does not catch missing features that userspace needs, which is what [dead-lan.md](dead-lan.md) is about.
