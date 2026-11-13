# The dead LAN, and two smaller lessons

## What happened

The first OpenWrt image booted. The Wi-Fi network showed up with the right name and channel, and a PC could associate. The BSSID was the router's real MAC, so the MAC sector was read fine. Then nothing: no ARP reply, no DHCP on the cable, no address on either side.

## Why

The kernel trim had turned off `CONFIG_BRIDGE_VLAN_FILTERING`. The bridge did not use VLAN filtering, so it looked safe to cut. But netifd creates every bridge with one rtnetlink `RTM_NEWLINK` message, and that message always carries `IFLA_BR_VLAN_FILTERING`, even when the value is 0:

```c
nla_put_u8(msg, IFLA_BR_VLAN_FILTERING, !!cfg->vlan_filtering);
```

With the option off, the kernel's stub refuses any value, 0 included:

```c
static inline int br_vlan_filter_toggle(struct net_bridge *br,
					unsigned long val,
					struct netlink_ext_ack *extack)
{
	return -EOPNOTSUPP;
}
```

The kernel deletes the new bridge and returns the error. netifd logs `Error adding bridge 'br-lan': -10` at debug level only and gives up on the LAN: no `br-lan`, no LAN address, no DHCP. Wi-Fi and the cable both hang off `br-lan`, so both were silent.

The AP still beaconed because hostapd, told `bridge=br-lan` and not finding it, creates a bare bridge with the old ioctl, which never sends that attribute. That bridge had the radio in it and no address. Clients associated and talked to nobody.

The fix was the stock value, `BRIDGE_VLAN_FILTERING=y`, for 10,026 bytes of kernel. A cheaper alternative, not used: patch the stub to `return val ? -EOPNOTSUPP : 0;`.

## Why the tests missed it

- The QEMU images ran the stock malta kernel, which has the option on. The userspace was tested; the kernel config was not.
- The bridge test looked for a `br-lan` with the AP in it. hostapd's bare bridge passed that check.
- The pre-flash audit rated the option safe because "bridge VLAN filtering is only generated for DSA boards". True for the uci config, wrong for what netifd sends.

Applying the router's networking trim to the malta kernel reproduced it: with the option off, `Error adding bridge 'br-lan': -10` and the LAN tests fail; with it on, everything passes. That is now the routernet suite in `qemu-malta/`, and the bridge tests check that the Ethernet port is in the bridge and the LAN has its address. `tools/imgcheck.py` also counts the `vlan_filtering` string in the decompressed kernel; it must be at least 1.

**Rule:** for every kernel option you turn off, look at what userspace sends to the kernel unconditionally, not only at what your config turns on. netifd's bridge setup is one netlink message with a dozen attributes.

## How I got back in

Failsafe ([recovery.md](recovery.md), section 5). In failsafe OpenWrt does not start netifd at all: it puts 192.168.1.1 straight on the LAN port and starts dropbear, so the missing bridge did not matter.

## Lesson 2: the empty board_name

After the fix, `sysupgrade -T` refused valid images because `/tmp/sysinfo/board_name` was empty. OpenWrt fills it at boot with `strings /proc/device-tree/compatible`, and `strings` was one of the busybox applets I had cut. Without `board_name`, sysupgrade refuses every image and no LED config is generated. `strings` is back (524 bytes of rootfs), and the QEMU base suite checks `board_name`.

## Lesson 3: a keep-settings upgrade across that fix (F2)

A network config generated while `board_name` was empty bridges plain `eth0` and has no `switch` section. The fixed image knows the board, so preinit sets up `switch0` with VLAN 1 (`0t 1 2 3 4`) from `board.json`, while netifd only touches the switch when a `switch` section exists. After a keep-settings upgrade the CPU port's untagged frames were dropped and the cable LAN was dead again.

`files-bench/etc/uci-defaults/95-bench-switch` migrates such a config: it replaces `eth0` in `br-lan` with the LAN device from `board.json` (`eth0.1`) and runs `generate_switch` from `/bin/config_generate`, so the switch sections are the stock ones. It does nothing on any other config. `qemu-malta/tests-f2.sh` checks both the migration and the no-op cases. If you never ran an image without `strings`, the script stays a no-op for you.
