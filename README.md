# OpenWrt 24.10 on a TP-Link TL-WR740N v5 (4 MB flash), without serial

Build setup, size tooling, recovery script, a small web UI and a QEMU test setup for running OpenWrt 24.10.8 with Wi-Fi on a TL-WR740N v5: Atheros AR9330, 4 MB SPI flash, 32 MB RAM. There is no official OpenWrt image for this board that includes Wi-Fi, because the ImageBuilder output does not fit. This one is built from source and trimmed until it does.

The story behind it is in the blog post: [TL-WR740N v5: OpenWrt 24.10 on 4 MB Without a Serial Cable](https://blog.aydindogm.us/posts/tl-wr740n-openwrt/).

## Status

Archive. It works on my unit: the image in this repository (with my own overlay values) has run on the router since November 2026, and the keep-settings upgrade path, including the network migration for old configs ([docs/dead-lan.md](docs/dead-lan.md), "F2"), passed on the hardware. The QEMU suites were last run before the current web page and the WAN change. There is no support, no release images and no promise that it works on yours. Flashing a 4 MB router without serial can brick it; read [docs/recovery.md](docs/recovery.md) before you touch the flash.

No firmware images, flash dumps or calibration data are in this repository. You build the image yourself, and your recovery image comes from your own flash dump.

## What the image has

ath9k with WPA2, WPA3-SAE, 802.11r and OWE (hostapd, AP only), dropbear with ed25519 and RSA keys (key-only login), `tc` with netem, `iperf3`, `tcpdump-mini`, `ethtool`, `mdio-tools`, dnsmasq, and a web UI on busybox httpd. No firewall, no IPv6, no opkg, no udhcpc, no LuCI (it does not fit). Kernel plus rootfs end 6,040 bytes under the 3,669,504-byte limit; the writable overlay is 324 KiB.

It was made for a test bench: a first-boot Wi-Fi AP bridged into the LAN (WPA2 with your `WIFI_KEY`), no firewall, no PPPoE, and WAN set to `proto none` (there is no DHCP client). An NTP server for a LAN without internet is optional (`LAN_NTP=1`, below). Do not put it on the internet as your home router.

## Layout

| Path | What |
|---|---|
| `build/` | `build.sh` (clone OpenWrt v24.10.8, patch, build in Docker), `diffconfig.txt`, `kernel-trim.config`, `openwrt-source.patch`, `packages.txt`, `prepare-files.sh` (assembles the files overlay), `measure.sh` / `step.sh` / `ablate.sh` / `probe-web.sh` (size measurements), `seeds/` (configs of the measured steps) |
| `tools/` | `dtbcheck.py` (does every device-tree node of a trimmed kernel still have a driver?), `imgcheck.py` (TP-Link header, product id, overlay markers, `vlan_filtering` present), `settime.py` (set the router clock from a PC, for `LAN_NTP=1`) |
| `files-bench/` | first-boot defaults: LAN address, hostname, key-only SSH, WPA2 AP on channel 1 (open only with `WIFI_OPEN=1`), WAN `proto none`, `authorized_keys` placeholder, libiwinfo `devices.txt` cut to this board's radio |
| `files-web/` | the web UI and JSON API (busybox httpd + POSIX sh CGIs); API reference in its README |
| `files-ntp/` | optional overlay for `LAN_NTP=1`: NTP server on the LAN, DHCP option 42 |
| `webui/` | source of the web page (`page.html`, `core.js`) and `build-slim.py`, which writes the minified `files-web/www-bench/index.html` |
| `recovery/` | `recovery-flash.sh` (U-Boot TFTP recovery server with checks), `make-recovery-image.sh` (cut your recovery image from your dump) |
| `qemu-malta/` | QEMU test of the same userspace on OpenWrt's malta/be target, with hwsim Wi-Fi; see its README |
| `docs/` | [recovery](docs/recovery.md), [size budget](docs/size-budget.md), [the near-brick](docs/near-brick.md), [the dead LAN](docs/dead-lan.md) |

## Build

You need Linux, Docker, git and about 15 GB of disk. The build runs as the `ubuntu` user (UID 1000) inside an Ubuntu 24.04 container and writes to the bind-mounted source tree, so your host user needs UID 1000 too (`id -u`).

```sh
export AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub   # required: the image allows key-only SSH
export WIFI_KEY=ChooseYourOwnKey42              # required: WPA2 key, 8 to 63 letters or digits
export WIFI_COUNTRY=DE                          # your country code
cd build && ./build.sh
./measure.sh final                              # sizes and margin
../tools/dtbcheck.py src/bin/targets/ath79/tiny/*-sysupgrade.bin /tmp/dtb
../tools/imgcheck.py src/bin/targets/ath79/tiny/*-factory.bin /tmp/img
```

The images land in `build/src/bin/targets/ath79/tiny/`. The first build takes one to two hours.

`./build.sh overlay /tmp/ov` only assembles the files overlay into a new directory, with the same checks, and needs no Docker. Use it to see what goes into the image. The overlay step stops when the sources hold an editor backup (`*.bak*`, `*~`, `*.orig`, `*.swp`): such a file would go into the image, and one 17 KB copy of a README once made the image too big to build.

`build.sh` applies `openwrt-source.patch` only to a tree that does not have it yet, and stops when `src/` has a different version of it. If you built from an older checkout of this repository, revert the old patch first (`git show <old commit>:build/openwrt-source.patch | git -C src apply -R`) or start from a fresh `src/`.

Overlay values come from the environment (see `build/prepare-files.sh`):

| Variable | Default | Used for |
|---|---|---|
| `LAN_IP` | 192.168.1.1 | LAN address (/24) |
| `ROUTER_HOSTNAME` | wr740n | hostname, web page title |
| `WIFI_SSID` | wr740n | SSID of the first-boot AP and the web UI's Wi-Fi profiles |
| `WIFI_KEY` | (required) | WPA2 key of the first-boot AP and the web UI's profiles, 8 to 63 letters/digits. It is stored in the image, so do not share an image built with your key. |
| `WIFI_OPEN` | 0 | 1 builds an open first-boot AP instead (anyone in range is on your LAN). Only for an isolated bench. |
| `WIFI_COUNTRY` | US | regulatory domain. Set your own |
| `AUTHORIZED_KEYS` | none | SSH public key file. The build stops without one |
| `NO_WEB=1` | | leave the web UI out |
| `LAN_NTP=1` | 0 | add the NTP server for a LAN without internet (below) |

The web UI password is generated at first boot: `ssh root@$LAN_IP cat /etc/benchweb/password` (user `bench`). The Wi-Fi key for the encrypted profiles is generated at first boot too, in `/etc/benchweb/wifi.conf`.

The final image has about 6 KB of margin. Every byte you add to the overlay, including a longer SSID, counts. If `measure.sh` shows a negative margin the image does not build; if the rootfs crosses a 4 KiB boundary the overlay shrinks by 4 KiB. See [docs/size-budget.md](docs/size-budget.md).

## Optional: time server for a LAN without internet

On a test bench without internet, nothing gives the devices on the LAN the time. With `LAN_NTP=1` the router serves its own clock to the LAN:

- busybox ntpd runs with `-l` and no upstream server, so it answers as a stratum 1 server (`system.ntp.enable_server=1`, no `server` entries, bound to `lan`);
- dnsmasq hands out the router as NTP server, DHCP option 42 (`42,<LAN_IP>`). systemd-networkd uses it by default (`UseNTP=yes`), other clients may need it configured;
- sysntpd is disabled at boot. The router has no RTC, and after a reboot its clock is wrong (OpenWrt sets it to the newest file time under `/etc`). Busybox would serve that wrong time as stratum 1 and clients would take it. So the server stays off until a PC sets the clock and starts it.

`tools/settime.py` does that from a PC whose own clock is right: it logs the router's offset, writes the PC time over SSH at a second boundary and starts sysntpd. Run it once after each router reboot, or from cron every 10 minutes:

```sh
tools/settime.py --router 192.168.1.1                       # optional: --iface <if> --key <private key>
tools/settime.py --router 192.168.1.1 --query               # only show the offset
```

Status: tested live on the router by setting the same values with `uci`, not yet in a flashed image. In that test the replies had leap indicator 0, stratum 1 and root delay and dispersion 0, which systemd-timesyncd accepts; the offset after a push was under 0.1 ms over the cable; option 42 came back in a DHCPINFORM; the free-running router clock drifted 2 to 11 ppm (about 1 s a day at worst without pushes). `settime.py` here is a generalized copy of the script used in that test. The same lines in `99-bench` cost 200 bytes of rootfs in a test build. Limits: accuracy is the PC's push error plus drift since the last push, and a router reboot leaves the server off until the next push. If you have a real NTP server on the PC (for example chrony), point `system.ntp.server` at it instead: busybox then reports stratum 16 until it has synced and never hands out a wrong clock.

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
| Files for the OpenWrt image that are based on OpenWrt files: `files-bench/` (including the libiwinfo `devices.txt` line), `qemu-malta/files-malta-test/`, `qemu-malta/f2/board-wr740n-v5.json` | GPL-2.0-only |
| The web UI: `files-web/` and its source `webui/` (written from scratch; it only calls OpenWrt interfaces such as `rc.common`, `uci`, `jshn` and `sysupgrade`) | MIT |
| `files-ntp/` (written from scratch, sets uci options) | MIT |
| Scripts and tools: `build/*.sh`, `build/docker/`, `tools/`, `recovery/`, `qemu-malta/*.sh`, `qemu-malta/docker-qemu*/`, `qemu-malta/f2/*.sh`, `qemu-malta/f2/*.py` | MIT |
| Documentation (`README.md`, `docs/`, other `.md` files) | MIT |

Full texts are in [LICENSES/](LICENSES). Scripts carry SPDX headers. Files that end up in the router image have none, because every byte in the image counts; this table covers them. OpenWrt itself, which the build downloads, is under its own licenses.

TP-Link and OpenWrt are trademarks of their owners. This project is not affiliated with either.
