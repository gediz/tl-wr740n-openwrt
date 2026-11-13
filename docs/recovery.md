# Recovery rules for the TL-WR740N v5

Everything here was read from one unit's flash dump and checked on that unit. The TFTP recovery ran for real once, with an OpenWrt factory image, and did what the disassembly said. Other hardware revisions or boot loader versions may differ. Check yours.

## Flash map

| Range | What | Write? |
|---|---|---|
| `0x000000` to `0x00ffff` | U-Boot 1.1.4 | never |
| `0x010000` to `0x01ffff` | MAC at `0x1fc00`, product id at `0x1fd00`, WPS PIN at `0x1fe00`, rest `0xff` | never |
| `0x020000` to `0x3dffff` | firmware, `0x3c0000` bytes: TP-Link v1 header, kernel, squashfs | yes |
| `0x3e0000` to `0x3effff` | DD-WRT nvram (the OpenWrt overlay reuses it) | yes |
| `0x3f0000` to `0x3fffff` | ART, the Wi-Fi calibration. Unique per unit | never |

Lose the first 128 KiB and you need an SPI programmer, and the TFTP recovery is gone with it. Lose ART and the only copy is your backup.

DD-WRT's partition names are misleading: its `uboot-env` partition is not a U-Boot environment, it is the MAC/id/PIN sector above.

## 1. Dump everything first

From DD-WRT (where `mtd6` is the whole 4 MiB):

```sh
ssh root@<router> 'dd if=/dev/mtdblock6' > fullflash.bin
ssh root@<router> 'md5sum /dev/mtdblock6'    # compare with md5sum fullflash.bin
```

From OpenWrt, `/proc/mtd` lists the partitions; dump each one the same way and check that each is an exact slice of the full dump. Keep a second copy somewhere other than your PC. These files contain your MAC address, WPS PIN and calibration data: do not publish them.

## 2. The TFTP recovery, as the boot loader does it

With the WPS/RESET button held at power-on (GPIO11, debounced), U-Boot turns the LED on, waits 2 s, sets itself to `192.168.0.86` and runs `tftp 80800000 wr740nv5_tp_recovery.bin` against a server at `192.168.0.66`. Then it compares 8 bytes at flash `0x1fd00` with 8 bytes at file offset `0x40` (the product id, `07400005 00000001` on the v5):

| File | U-Boot does |
|---|---|
| id differs | prints `product id verify fail`, boots the old firmware, writes nothing |
| id matches, size `0x3c0000` | erases and writes `0x020000` to `0x3dffff`, resets |
| id matches, size `0x3e0200` (stock image with boot block) | writes file+`0x20200` to the same range, resets |
| id matches, any other size | resets, writes nothing |

It never writes U-Boot, the MAC/id sector, the nvram block or ART. The environment is compiled in (`Using default environment`, no `saveenv`), so nothing stale in flash changes this. Only the `0x3c0000` branch has run on real hardware; the other branches are read from the disassembly.

So the right file is a factory image for this board (`0x3c0000` bytes, id at `0x40`), never a sysupgrade image (about `0x380338` bytes, which falls into "resets, writes nothing").

## 3. Make your recovery image from your dump

The firmware partition of a working router is already in the format the recovery accepts. Cut it out:

```sh
recovery/make-recovery-image.sh fullflash.bin wr740nv5_tp_recovery.bin
```

It cuts `0x020000` + `0x3c0000` bytes (`dd bs=64k skip=2 count=60`) and checks that the id at `+0x40` matches the id at `0x1fd00` in your dump. Flashing it puts the router back to the firmware you dumped. The nvram block is not touched by recovery, so if OpenWrt ran in between and reused that block, DD-WRT comes back with default settings.

## 4. Run it

Use a wired interface that is only cabled to a router LAN port (a USB Ethernet adapter works well). The script refuses an interface that carries a default route, so your internet stays where it is.

```sh
cd recovery
./recovery-flash.sh --iface enx001122334455 --file wr740nv5_tp_recovery.bin --sha256 <sum> --dry-run
./recovery-flash.sh --iface enx001122334455 --file wr740nv5_tp_recovery.bin --sha256 <sum> --check-ip 192.168.1.1
```

It checks size and id, makes the interface unmanaged in NetworkManager for the run, puts `192.168.0.66/24` on it, runs dnsmasq as a TFTP-only server (`--port=0` turns DNS off) and tcpdump next to it, and prints the ARP request, the read request and transfer progress. Then:

1. Start the script and wait for `TFTP listening` and the `NOW:` prompt.
2. Power off, hold WPS/RESET, power on, count to 5, let go.
3. About 20 s later the router asks for the file; the 3.75 MiB transfer took 10 s on my unit (cable in LAN 2; other ports not tried).
4. The script waits 150 s for erase, write and restart. Do not pull the power. On my unit the link went down and up twice in the first 45 s and OpenWrt answered ping right after the wait.

After an aborted run: `./recovery-flash.sh --iface <if> --cleanup`.

**Hold the button about 5 seconds, not longer.** If no TFTP server answers, U-Boot boots the firmware in flash. If the button is still held when OpenWrt's preinit runs, OpenWrt enters failsafe (fast-blinking system LED). That is how my first "recovery run" ended up in failsafe instead.

## 5. Failsafe plus sysupgrade

When OpenWrt is on the flash and boots, failsafe is the other way in. It does not start netifd and does not need the bridge, which is why it worked when the LAN was dead ([dead-lan.md](dead-lan.md)).

1. Press WPS/RESET while OpenWrt boots (system LED blinks fast). Failsafe puts `192.168.1.1/24` on the LAN ports only (no Wi-Fi, no DHCP) and starts dropbear with the image's `authorized_keys`.
2. From a host on the cable with a static `192.168.1.x`, copy a **sysupgrade** image (not factory) to `/tmp` and check its sha256.
3. If `/tmp/sysinfo/board_name` is empty, sysupgrade refuses every image. Write it: `echo tplink,tl-wr740n-v5 > /tmp/sysinfo/board_name`. (It was empty on my image because busybox `strings` had been cut; see [dead-lan.md](dead-lan.md).)
4. `sysupgrade -T /tmp/<image>` must pass. Then `FAILSAFE=1 sysupgrade -n /tmp/<image>`. Plain `sysupgrade` goes through ubus and fails in failsafe.

If the PC has no cable to the router, SSH over another host's serial console also works: `stty raw -echo; nc 192.168.1.1 22` on that host, a small serial-to-stdio script as `ProxyCommand` on the PC. Slow, but a 3.7 MB image goes through.

## Ways to put an image on, cheapest first

| Way | Needs |
|---|---|
| SSH `sysupgrade` | working OpenWrt and your key |
| Web UI `/cgi-bin/upgrade` | working OpenWrt and the web password |
| Failsafe + `sysupgrade -n` | OpenWrt in flash, the button, a host on the cable |
| U-Boot TFTP with a factory image | the button and a cable to a LAN port. Works whatever is in the firmware area |
| Serial (ttyS0, 115200) | an adapter and opening the case. Not tried |
