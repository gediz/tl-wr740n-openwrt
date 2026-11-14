# Size budget

## The limit

The TP-Link 4Mlzma layout gives header + kernel + rootfs at most 3,670,016 bytes: the `0x3c0000` firmware area minus 256 KiB that `mktplinkfw` keeps back for the writable overlay. `mktplinkfw` counts the 512-byte header against that and rounds the kernel up to 4 bytes (`mktplinkfw.c:316-321`), so kernel + rootfs may use **3,669,504 bytes**. `build/measure.sh` prints the margin against that number.

The overlay (`rootfs_data`) starts at the end of the squashfs rounded up to 4 KiB and ends at `0x3d0000`. Growing the rootfs across a 4 KiB boundary costs 4 KiB of overlay even when the image still fits. The final image's rootfs ends at `0x37e868`, 1,944 bytes before such a boundary.

## Final image

| Item | Bytes |
|---|---|
| Kernel (LZMA, with DTB) | 1,312,886 |
| Rootfs (squashfs, xz, 256 KiB blocks) | 2,350,576 |
| Margin (kernel rounded to 4 bytes) | 6,040 |
| Overlay (`0x37f000` to `0x3d0000`, 4 KiB erase) | 331,776 (324 KiB) |

Stock 24.10.8 defaults for this board came out at 5,193,361 bytes, about 1.5 MB over. These numbers are for the overlay values I built with; yours change the rootfs by a few bytes. `LAN_NTP=1` adds about 200 bytes (measured with the same lines in `99-bench`).

## The last round: a bigger web page and a smaller rootfs

The web page grew from 3.2 KB to 17.8 KB (`webui/`, the minified build). That cost 5,528 bytes of rootfs, and these files that nothing on the router reads paid for it:

| Change | Saved (bytes) | Effect |
|---|---|---|
| opkg `*.list` files removed (`include/rootfs.mk`) | 3,770 | `sysupgrade -o` (whole-overlay backup) can no longer leave out package files. `sysupgrade -b` and the web backup do not use them |
| libiwinfo `devices.txt` cut to the AR9330 line (`files-bench/usr/share/libiwinfo/`) | 2,608 | iwinfo would show "unknown" hardware for any other radio; this board has only that one |
| opkg `*.prerm` scripts removed | 1,214 | none: only opkg runs them, and opkg is not in the image |
| `/usr/share/udhcpc` removed | 520 | none: udhcpc is not in the image |
| `/etc/opkg` removed | 136 | none |
| Page minified (esbuild for CSS and JS, whitespace between tags) | about 500 | none: same markup and logic |

Net: rootfs 2,352,458 to 2,350,576 bytes, margin 4,158 to 6,040, overlay unchanged at 324 KiB. `/usr/lib/opkg/status` and the `*.control` and `*.conffiles` files stay, because `sysupgrade -b` finds changed config files through them. The per-item numbers are single changes measured with the build's own mksquashfs, about 10 bytes of noise each.

Measured and not used:

| Option | Saved (bytes) | Why not |
|---|---|---|
| All of `/usr/lib/opkg` | 11,814 | `sysupgrade -b` and the web backup would miss changed conffiles (`/etc/passwd`, `/etc/shadow` and others) |
| Squashfs 512 KiB blocks | 31,528 | about 1.25 MiB more RAM for squashfs caches for as long as the router runs |
| `/etc/services`, `/etc/protocols` | 2,240 | libc port and protocol name lookups |
| Cutting page features (icon, hints, confirms, reboot wait, tables) | under 1,000 together | not worth losing them |

## What each change saved

Each change was built on top of the previous one and measured with a real image. Sorted by savings; the order I measured them in differs, and some numbers would move a bit in another order. `build/seeds/` has the configs of the steps, `build/ablate.sh` reruns the first part.

| Change | Saved (bytes) |
|---|---|
| Drop firewall4/nftables, ppp, odhcp6c/odhcpd, opkg, usign, ca-bundle, uclient-fetch, urngd, ujail; wpad replaced by hostapd | 1,020,393 |
| Kernel trim round 1 (no PCI, USB, netfilter, BPF syscall, unused drivers; SLUB_TINY, BASE_SMALL) | 393,141 |
| Squashfs block size 64 to 256 KiB | 119,858 |
| IPv6 off (kernel and packages) | 110,479 |
| Ship only libmbedcrypto, link hostapd with `-lmbedcrypto` | 85,854 |
| Stack protector, FORTIFY_SOURCE, RELRO, seccomp off | 70,487 |
| mac80211 mesh and debugfs off, ATH_DFS off | 70,324 |
| `CONFIG_BUG=n` | 56,684 |
| kmod-netem depends on kmod-sched-core only | 40,962 |
| mbedtls `-Os`, P-256 only, no DES, no TLS 1.3 | 30,944 |
| Busybox: 20 applets off (udhcpc, swap tools, less, brctl, ...) | 25,928 |
| Debugfs, sysrq, printk time, multicast routing off | 25,884 |
| Kernel round 2 (no initrd, no ethtool netlink, no SYN cookies, 16 KiB log) | 20,851 |
| kmod-crypto-ctr without the IPsec-only crypto it pulled in | 14,836 |
| hostapd: ACS, MBO, wired driver, preauth, airtime policy off | 9,344 |
| dnsmasq: no TFTP, loop detection, inotify, dumpfile | 6,384 |
| Dropbear: ed25519 on, ECC/U2F/client/agent/zlib off | 6,016 |
| `--gc-sections` | 524 (rejected) |

Put back later, because they were needed:

| Option | Cost (bytes) | Why |
|---|---|---|
| `SPI_AR934X=y`, `AR8216_PHY=y` | 8,480 kernel | flash and switch drivers ([near-brick.md](near-brick.md)) |
| `BRIDGE_VLAN_FILTERING=y` | 10,026 kernel | netifd cannot create any bridge without it ([dead-lan.md](dead-lan.md)) |
| `JFFS2_FS_XATTR`, `TMPFS_XATTR` | 5,217 kernel | without them overlayfs fails `rmdir`/`mkdir` over lower-layer dirs with EIO |
| busybox `strings` | 524 rootfs | preinit fills `board_name` with it; without it sysupgrade refuses every image |
| busybox httpd + web UI + Wi-Fi defaults | 12,736 rootfs | the web UI (with the first 3.2 KB page; the current page costs 5,528 more, see above) |

The source changes are in `build/openwrt-source.patch`: IPv6 made selectable, kmod-crypto-ctr without seqiv, kmod-netem on sched-core, mbedtls `-Os` and libmbedcrypto only, hostapd linked to libmbedcrypto with features off, dnsmasq and uhttpd trimmed, a guard for a `wpa_supplicant` ubus call when there is no wpa_supplicant, the opkg and udhcpc leftovers deleted in `include/rootfs.mk`, and the kernel trim appended to `target/linux/ath79/tiny/config-default`.

## What does not fit

LuCI. A minimal LuCI costs about 350 KB; with the tools above it ends up about 300 KB over. 1 MiB squashfs blocks would save another 80 KB and cost 3 to 4 MiB of RAM for caches, which still does not close the gap.

Tried and dropped:

| Idea | Result |
|---|---|
| Squashfs 128 / 512 / 1024 KiB blocks (vs 64) | saves 62,798 / 160,250 / 198,046. Kept 256 KiB as the RAM trade-off |
| `CONFIG_USE_LTO` | does not build: MIPS16 shared objects fail with `R_MIPS16_26` relocation errors |
| Kernel LZMA parameters | best variant saved 324 bytes |
| Removing iwinfo | not possible: netifd's `mac80211.sh` uses it |
| `CONFIG_BUG=y` back on | costs 54,738 bytes, about nine times the margin |

## The web server

| Option | Rootfs cost (bytes) |
|---|---|
| busybox httpd, plain | 2,208 |
| busybox httpd with CGI, basic auth, MD5 | 4,232 |
| uhttpd without TLS or modules | 18,304 |

`build/probe-web.sh` reruns this probe.
