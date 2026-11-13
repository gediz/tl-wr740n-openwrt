# OpenWrt 24.10 on a TP-Link TL-WR740N v5 (4 MB flash), without serial

Build setup, size tooling, recovery script, a small web UI and a QEMU test setup for running OpenWrt 24.10.8 with Wi-Fi on a TL-WR740N v5: Atheros AR9330, 4 MB SPI flash, 32 MB RAM. There is no official OpenWrt image for this board that includes Wi-Fi, because the ImageBuilder output does not fit. This one is built from source and trimmed until it does.

The story behind it is in the blog post: [TL-WR740N v5: OpenWrt 24.10 on 4 MB Without a Serial Cable](https://blog.aydindogm.us/posts/tl-wr740n-openwrt/).

## Status

Archive. It works on my unit. There is no support, no release images and no promise that it works on yours. Flashing a 4 MB router without serial can brick it; read [docs/recovery.md](docs/recovery.md) before you touch the flash.

No firmware images, flash dumps or calibration data are in this repository. You build the image yourself, and your recovery image comes from your own flash dump.

## What the image has

ath9k with WPA2, WPA3-SAE, 802.11r and OWE (hostapd, AP only), dropbear with ed25519 and RSA keys (key-only login), `tc` with netem, `iperf3`, `tcpdump-mini`, `ethtool`, `mdio-tools`, dnsmasq, and a web UI on busybox httpd. No firewall, no IPv6, no opkg, no LuCI (it does not fit). Kernel plus rootfs end 4,158 bytes under the 3,669,504-byte limit; the writable overlay is 324 KiB.

It was made for a test bench: an open first-boot SSID, no firewall, no PPPoE. Do not put it on the internet as your home router.

## Layout

| Path | What |
|---|---|
| `build/` | `build.sh` (clone OpenWrt v24.10.8, patch, build in Docker), `diffconfig.txt`, `kernel-trim.config`, `openwrt-source.patch`, `packages.txt`, `prepare-files.sh` (assembles the files overlay), `measure.sh` / `step.sh` / `ablate.sh` / `probe-web.sh` (size measurements), `seeds/` (configs of the measured steps) |
| `tools/` | `dtbcheck.py` (does every device-tree node of a trimmed kernel still have a driver?), `imgcheck.py` (TP-Link header, product id, overlay markers, `vlan_filtering` present) |
| `files-bench/` | first-boot defaults: LAN address, hostname, key-only SSH, open AP on channel 1, `authorized_keys` placeholder |
| `files-web/` | the web UI and JSON API (busybox httpd + POSIX sh CGIs); API reference in its README |
| `recovery/` | `recovery-flash.sh` (U-Boot TFTP recovery server with checks), `make-recovery-image.sh` (cut your recovery image from your dump) |
| `qemu-malta/` | QEMU test of the same userspace on OpenWrt's malta/be target, with hwsim Wi-Fi; see its README |
| `docs/` | [recovery](docs/recovery.md), [size budget](docs/size-budget.md), [the near-brick](docs/near-brick.md), [the dead LAN](docs/dead-lan.md) |

## Build

You need Linux, Docker, git and about 15 GB of disk. The build runs as the `ubuntu` user (UID 1000) inside an Ubuntu 24.04 container and writes to the bind-mounted source tree, so your host user needs UID 1000 too (`id -u`).

```sh
export AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub   # required: the image allows key-only SSH
export WIFI_COUNTRY=DE                          # your country code
cd build && ./build.sh
./measure.sh final                              # sizes and margin
../tools/dtbcheck.py src/bin/targets/ath79/tiny/*-sysupgrade.bin /tmp/dtb
../tools/imgcheck.py src/bin/targets/ath79/tiny/*-factory.bin /tmp/img
```

The images land in `build/src/bin/targets/ath79/tiny/`. The first build takes one to two hours.

Overlay values come from the environment (see `build/prepare-files.sh`):

| Variable | Default | Used for |
|---|---|---|
| `LAN_IP` | 192.168.1.1 | LAN address (/24) |
| `ROUTER_HOSTNAME` | wr740n | hostname, web page title |
| `WIFI_SSID` | wr740n | SSID of the open first-boot AP and the web UI's Wi-Fi profiles |
| `WIFI_COUNTRY` | US | regulatory domain. Set your own |
| `AUTHORIZED_KEYS` | none | SSH public key file. The build stops without one |
| `NO_WEB=1` | | leave the web UI out |

The web UI password is generated at first boot: `ssh root@$LAN_IP cat /etc/benchweb/password` (user `bench`). The Wi-Fi key for the encrypted profiles is generated at first boot too, in `/etc/benchweb/wifi.conf`.

The final image has a few KB of margin. Every byte you add to the overlay, including a longer SSID, counts. If `measure.sh` shows a negative margin the image does not build; if the rootfs crosses a 4 KiB boundary the overlay shrinks by 4 KiB. See [docs/size-budget.md](docs/size-budget.md).

## Flash

1. Make a full flash dump first and keep it off your PC ([docs/recovery.md](docs/recovery.md)).
2. Test the userspace in QEMU, including the routernet suite ([qemu-malta/README.md](qemu-malta/README.md)).
3. Run `dtbcheck.py` and `imgcheck.py` on the image.
4. Have a working way back before you flash: TFTP recovery with an image cut from your dump.
5. From stock or DD-WRT: the **factory** image (via TFTP recovery or the vendor upgrade path). From OpenWrt: the **sysupgrade** image.

## Licenses

| What | License |
|---|---|
| `build/openwrt-source.patch`, `qemu-malta/malta-source.patch` (patches to OpenWrt) | GPL-2.0-only |
| Build configs derived from OpenWrt: `build/diffconfig.txt`, `build/kernel-trim.config`, `build/seeds/`, `build/ablation/`, `build/packages.txt`, `qemu-malta/diffconfig-malta*.txt`, `qemu-malta/config-default.malta-be.plain` | GPL-2.0-only |
| Files for the OpenWrt image that are based on OpenWrt files: `files-bench/`, `qemu-malta/files-malta-test/`, `qemu-malta/f2/board-wr740n-v5.json` | GPL-2.0-only |
| The web UI: `files-web/` (written from scratch; it only calls OpenWrt interfaces such as `rc.common`, `uci`, `jshn` and `sysupgrade`) | MIT |
| Scripts and tools: `build/*.sh`, `build/docker/`, `tools/`, `recovery/`, `qemu-malta/*.sh`, `qemu-malta/docker-qemu*/`, `qemu-malta/f2/*.sh`, `qemu-malta/f2/*.py` | MIT |
| Documentation (`README.md`, `docs/`, other `.md` files) | MIT |

Full texts are in [LICENSES/](LICENSES). Scripts carry SPDX headers. Files that end up in the router image have none, because every byte in the image counts; this table covers them. OpenWrt itself, which the build downloads, is under its own licenses.

TP-Link and OpenWrt are trademarks of their owners. This project is not affiliated with either.
