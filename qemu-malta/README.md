# QEMU test of the TL-WR740N userspace (OpenWrt 24.10.8, malta/be)

QEMU cannot emulate the AR9331 SoC, the ath9k radio or the switch. This setup builds the OpenWrt `malta` target (big-endian MIPS 24Kc, the same CPU family as ath79) with the same userspace as the router image in `../build`, plus `mac80211_hwsim` for Wi-Fi. It tests the userspace and the configuration, not the router kernel or its drivers. For those, use `../tools/dtbcheck.py` and the hardware.

Everything runs in Docker. The test runner containers are started with `--network none`: they only have loopback, and QEMU's tap bridge and user-mode NIC live inside the container's own network namespace. Nothing in a test can reach your LAN or a real router.

## Quick start

```sh
export AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub   # baked into the guest image (see ../build/prepare-files.sh)
export SSH_KEY=~/.ssh/id_ed25519                # the matching private key, mounted read-only into the runner
./build.sh                  # plain image (no web UI), 1 to 2 h the first time
./run.sh 32                 # tests.sh at 32 MB RAM, about 6 min
./build-web.sh              # image with the web UI, after build.sh
./run-web.sh 32             # tests-web.sh, about 15 min
```

The QEMU build scripts set `WIFI_OPEN=1` unless you set it: the tests associate a client to the first-boot AP inside the VM's private network, and the open AP needs no shared key. If you build with non-default overlay values (`LAN_IP`, `ROUTER_HOSTNAME`, `WIFI_SSID`, `WIFI_COUNTRY`), export the same values for the `run-*.sh` scripts: the tests check them. `SSH_KEY_RSA` (default `~/.ssh/id_rsa`) is optional; without it the RSA login test reports SKIP. For it to pass, the RSA public key must also be in `AUTHORIZED_KEYS`.

## Pre-flash check: routernet

Run this before flashing a new router image. The plain and web images use the stock malta kernel, and that is how a dead-LAN bug got past them (`../docs/dead-lan.md`): the router kernel had `CONFIG_BRIDGE_VLAN_FILTERING` off, the malta kernel had it on. The routernet image is the web image with a malta kernel that also gets the router kernel's networking trim.

```sh
./build-routernet.sh          # 2 to 5 min after build-web.sh, output in images-routernet/
./run-routernet.sh base 32    # tests.sh
./run-routernet.sh web 32     # tests-web.sh
./run-routernet.sh f2 32      # tests-f2.sh
```

The three suites run in separate containers, so they can run at the same time. Logs go to `logs/routernet/`.

`build-routernet.sh` appends the `# Networking` block of `../build/kernel-trim.config` and the networking options of its `# Round 2` to the plain malta `config-default` (`config-default.malta-be.plain`), reading them from `kernel-trim.config` on every run. It then writes `images-routernet/routernet-kconfig.txt`: each of these options with its value in the router's built kernel `.config` (from `../build/src`, so build the router image first) and in the malta one. They must agree. Afterwards it puts the tree back to the plain setup and cleans the kernel.

Still not covered: the router kernel's other trims (memory, block, MTD, serial, `CONFIG_BUG`), ath9k, the AR7240 switch and the flash.

## What the suites check

| Suite | Checks |
|---|---|
| `tests.sh` (T1 to T10) | first boot and uci-defaults, key-only SSH (ed25519, RSA, password refused), DHCP to a client on the private bridge, the open AP at first boot with a real STA association, WPA2/WPA3-SAE/mixed/802.11r/OWE associations over hwsim, netem, iperf3, overlay whiteouts on tmpfs and on JFFS2 (block2mtd), `board_name`, memory at idle |
| `tests-web.sh` (W1 to W18, S1 to S9) | every web UI endpoint, auth, Host/Origin checks, input whitelists, uploads (restore and two-step sysupgrade to a "variant B" image), factory reset on a real overlay, a slow upload, a connection flood (only httpd may be OOM-killed), and that the CGI directory holds only the scripts afterwards |
| `tests-f2.sh` | the network migration in `../files-bench/etc/uci-defaults/95-bench-switch`, as unit cases in the guest and end to end through a keep-settings sysupgrade |

The last results on the final userspace: 23 PASS in the base suite and 45 PASS in the web suite, nothing failed. Idle `MemAvailable` was about 5.5 MB at 32 MB RAM with the AP and a test client up. The stock malta kernel leaves about 6.5 MB less free RAM than the trimmed router kernel, so the router has more headroom than that.

## Files

| File | Content |
|---|---|
| `build.sh` | rebuild from scratch (clone, feeds, patch, overlay, config, make) in container `owrt-src-malta` |
| `diffconfig-malta.txt` | build config: the router's `diffconfig.txt` with the target switched, plus test extras |
| `diffconfig-malta-web.txt` | the same plus busybox httpd (CGI, basic auth, MD5) and a squashfs rootfs, output to `/src/bin-web` |
| `malta-source.patch` | every change to the OpenWrt tree (same package patches as the router, plus malta test bits) |
| `config-default.malta-be.plain` | OpenWrt's plain malta be kernel `config-default`, the base for `build-routernet.sh` |
| `build-web.sh` | web image into `images-web/`, plus variant B (same image with `/etc/fw-variant`) and an overlay disk for the reset test |
| `build-routernet.sh`, `run-routernet.sh` | the pre-flash check above |
| `run.sh`, `run-web.sh` | host side: start a runner container and run a suite |
| `keys.inc.sh` | key and overlay-value handling shared by the `run-*.sh` scripts |
| `tests.sh`, `tests-web.sh`, `tests-f2.sh` | the suites; they run inside the runner container |
| `f2/` | `f2-guest.sh` (unit cases in the guest), `arpvlan.py` (tagged and untagged ARP probe on the tap), `board-wr740n-v5.json` (the router's `board.json`, generated by OpenWrt's board.d scripts) |
| `boot-debug.sh` | boots QEMU with the serial console on fifos, for manual debugging inside a runner |
| `docker-qemu/`, `docker-qemu-web/` | runner images (qemu-system-mips, ssh, iperf3, busybox udhcpc; curl and python3 for the web suite) |
| `files-malta-test/` | test-only sysupgrade hook: lets sysupgrade write a malta ext4 image to `/dev/sda` and keep settings |

## Network inside the runner

- guest eth0 (LAN, br-lan, `LAN_IP`) is a tap on a private bridge `br0` (`LAN_IP` with the last octet 2), with a veth pair on the same bridge for the DHCP client test
- guest eth1 (WAN) is a QEMU user-mode NIC with `hostfwd=tcp:127.0.0.1:2222-10.0.2.15:22`

## Differences from the router image

Same as the router: package versions, busybox config, hostapd-basic-mbedtls build options, dnsmasq options, mbedtls `-Os`, IPv6 off, no firewall, no opkg, no ujail, the same files overlay.

Different:

- Kernel: stock malta 6.6 config, not the trimmed ath79/tiny one (routernet adds only the networking trim). Memory totals are an approximation; per-process numbers carry over. The overlay-related options do match the router: `JFFS2_FS_XATTR` and `TMPFS_XATTR` on, POSIX ACLs and JFFS2 security labels off. Test only: `MTD_BLOCK2MTD=y`, so T9 can mount JFFS2 on a second IDE disk.
- Rootfs: ext4 on an IDE disk instead of squashfs + JFFS2 on flash (the reset test uses squashfs plus an ext4 `rootfs_data` overlay).
- Drivers: pcnet32 and mac80211_hwsim instead of ag71xx, the AR7240 switch and ath9k.
- Test-only packages: kmod-mac80211-hwsim, kmod-pcnet32, wpa-supplicant-mbedtls, wpa-cli, hostapd-utils, uhttpd. wpa_supplicant runs as a global daemon (about 1.4 MB RSS) that the router does not have.
- mbedtls: all of libmbedtls is installed and `MBEDTLS_KEY_EXCHANGE_ECDHE_RSA_ENABLED` is on, or wpa-supplicant-mbedtls does not link. hostapd still links only libmbedcrypto, as on the router.

## Two traps these tests fell into once

**Wi-Fi tests that passed without an AP.** `wifi config` picks the highest band the radio supports. hwsim supports every band, so it generated 6 GHz radios, and on 6 GHz hostapd refuses an open network ("Pre-RSNA security methods are not allowed in 6 GHz"). The AP interface existed, hostapd had died, and the early tests only read uci and `iw dev`. `99-bench` now sets band 2g and HT20 (what `wifi config` generates for the router's ath9k anyway), and the tests check that the AP is up, in the bridge, and that a client associates.

**Overlay permissions.** On a host with umask 002, `cp -a` copies group-writable `etc/` and `etc/dropbear/` into the image, and dropbear then refuses `authorized_keys`. With password login off, such an image can only be entered through failsafe. `../build/prepare-files.sh` fixes the modes.
