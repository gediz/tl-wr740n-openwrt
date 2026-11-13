#!/bin/bash
# SPDX-License-Identifier: MIT
# F2 migration test (/etc/uci-defaults/95-bench-switch from ../files-bench). Runs inside a runner container
# (run-routernet.sh f2, --network none). Usage: tests-f2.sh [RAM_MB]   (default 32)
# Writes /work/logs/f2-raw-<RAM>M.log and /work/logs/f2-summary-<RAM>M.txt.
#
# Part U (unit): boots overlay-disk.img.gz (squashfs root, so the image's own script is at /rom/etc/uci-defaults)
#   and runs f2/f2-guest.sh with the router's board.json (f2/board-wr740n-v5.json) and sample network configs.
# Part E (end to end): boots the ext4 image and makes it look like a router on an image without board_name:
#   malta's own network config already bridges plain eth0 with no switch section; the Wi-Fi goes back to
#   default_radio0 with no web profile. The router's board.json is kept over the upgrade (on the router the new
#   image regenerates it with switch0). Then sysupgrade keeping settings to variant B, and checks after the boot.
#   Malta has no switch: tap0 stands in for it. After the migration the LAN must answer on VLAN 1 only.
MEM=${1:-32}
W=/work
IMG=$W/images-web
F2=/opt/f2
RUN=/tmp/runf2
OUT=$W/logs/f2-raw-${MEM}M.log
SUM=$W/logs/f2-summary-${MEM}M.txt
KEY=/keys/id_ed25519
IP=${LAN_IP:-192.168.1.1}; NET=${IP%.*}   # overlay values, passed in by the run-*.sh scripts (keys.inc.sh)
SSID=${WIFI_SSID:-wr740n}; HN=${ROUTER_HOSTNAME:-wr740n}
SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o IdentitiesOnly=yes"
AP=phy0-ap0
VB=$IMG/variant-b-rootfs-ext4.img.gz

mkdir -p $RUN $W/logs
: > $OUT; : > $SUM
log() { echo "$*" | tee -a $OUT; }
res() { echo "$1 $2 $3" | tee -a $SUM | sed 's/^/RESULT /' >> $OUT; echo "RESULT $1 $2 $3"; }
r() { ssh $SSHO -i $KEY root@$IP "$@" 2>&1; }
rw() { ssh $SSHO -i $KEY -p 2222 root@127.0.0.1 "$@" 2>&1; }   # through the WAN NIC (hostfwd)
rl() { log "## guest: $*"; r "$@" | tee -a $OUT; }
waitssh() { for i in $(seq 1 ${1:-60}); do sleep 5; r true >/dev/null 2>&1 && return 0; done; return 1; }
waitsshw() { for i in $(seq 1 ${1:-60}); do sleep 5; rw true >/dev/null 2>&1 && return 0; done; return 1; }
waitdown() { for i in $(seq 1 ${1:-60}); do r true >/dev/null 2>&1 || return 0; sleep 2; done; return 1; }
arp() { python3 $F2/arpvlan.py tap0 $1 $IP $NET.3 3 2>&1; }   # arp VID (0 = untagged). Sender .3 is unused: the guest caches its fake MAC
boot() {  # boot DISK_IMAGE EXTRA_APPEND CONSOLE
  pkill -f qemu-system-mips; sleep 1
  qemu-system-mips -M malta -cpu 24Kc -m ${MEM}M -nographic -vga none -monitor none -serial file:$3 \
    -kernel $IMG/vmlinux.elf -append "root=/dev/sda $2 rootwait console=ttyS0" -drive file=$1,format=raw,if=ide \
    -nic tap,ifname=tap0,script=no,downscript=no,model=pcnet,mac=52:54:00:50:00:01 \
    -nic user,model=pcnet,mac=52:54:00:50:00:02,net=10.0.2.0/24,hostfwd=tcp:127.0.0.1:2222-10.0.2.15:22 \
    </dev/null >>$RUN/qemu.out 2>&1 &
}

ip link show br0 >/dev/null 2>&1 || {
  ip link add br0 type bridge
  ip addr add $NET.2/24 dev br0
  ip tuntap add tap0 mode tap
  ip link set tap0 master br0
  for i in br0 tap0 lo; do ip link set $i up; done
}

# ---------- Part U: unit cases on the image's own script ----------
log "== F2-U unit (overlay disk, script from /rom)"
zcat $IMG/overlay-disk.img.gz > $RUN/ov.img
boot $RUN/ov.img rootfstype=squashfs $RUN/console-u.log
if waitssh 120; then
  sleep 20
  rl "mount | grep -E ' on / type| on /overlay type'; ls -l /rom/etc/uci-defaults/; ls /etc/uci-defaults | wc -l"
  r "mkdir -p /tmp/f2" >/dev/null
  r "cat > /tmp/f2/router.json" < $F2/board-wr740n-v5.json
  r "cat > /tmp/f2/f2-guest.sh" < $F2/f2-guest.sh
  hs=$(r "md5sum < /rom/etc/uci-defaults/95-bench-switch"); hf=$(md5sum < /opt/files-bench/etc/uci-defaults/95-bench-switch)
  [ "$hs" = "$hf" ] && res F2-U-script PASS "/rom/etc/uci-defaults/95-bench-switch in the image = ../files-bench copy (md5 ${hs%% *})" \
    || res F2-U-script FAIL "image md5 '$hs' files-bench md5 '$hf'"
  r "sh /tmp/f2/f2-guest.sh /rom/etc/uci-defaults/95-bench-switch /tmp/f2/router.json $IP" > $RUN/u.out
  cat $RUN/u.out >> $OUT
  grep '^F2-U' $RUN/u.out | while read -r n s d; do res "$n" "$s" "$d"; done
  grep -qx restored $RUN/u.out || res F2-U-restore FAIL "guest /etc/config or /etc/board.json not restored"
  rl "cat /tmp/f2w/u1.cfg"
else
  tail -40 $RUN/console-u.log | tee -a $OUT; res F2-U0 FAIL "overlay disk did not boot"
fi
cp $RUN/console-u.log $W/logs/f2-console-u-${MEM}M.log
pkill -f qemu-system-mips; sleep 2

# ---------- Part E: keep-settings sysupgrade from an old-style config ----------
log "== F2-E end to end (ext4 image, sysupgrade keeping settings to variant B)"
zcat $IMG/openwrt-malta-be-rootfs-ext4.img.gz > $RUN/rootfs.ext4
boot $RUN/rootfs.ext4 "" $RUN/console-e.log
waitssh 120 || { tail -40 $RUN/console-e.log | tee -a $OUT; res F2-E0 FAIL "no ssh"; pkill -f qemu-system-mips; exit 1; }
sleep 20
# WAN gets the slirp address so ssh still works after the LAN moves to VLAN 1 (malta has no switch to untag it)
r "uci set network.wan.proto=static; uci set network.wan.ipaddr=10.0.2.15; uci set network.wan.netmask=255.255.255.0; uci commit network; ifup wan" >/dev/null
sleep 5
# old-style Wi-Fi: the AP in default_radio0, no web profile (images before 2026-11-12 16:00)
r "uci rename wireless.bench=default_radio0; uci commit wireless; rm -f /etc/benchweb/profile; wifi reload" >/dev/null
r "cat > /etc/board.json" < $F2/board-wr740n-v5.json
r "echo /etc/board.json >> /etc/sysupgrade.conf" >/dev/null
sleep 10
rl "uci show network | grep -E 'device|ports|switch'; uci show wireless | grep -E '=wifi-iface|\.ssid'; ls /etc/benchweb; ls /sys/class/net/br-lan/brif; grep -c switch0 /etc/board.json; sysupgrade -l | grep -E 'board.json|config/network|benchweb/'"
a0=$(arp 0); a1=$(arp 1)
log "before: untagged ARP: $a0; VLAN 1 ARP: $a1"
pre=$(r "uci -q get network.@switch[0] || echo no-switch; uci show network | sed -n \"s/.*@device\\[[0-9]*\\]\\.ports='\\(.*\\)'/\\1/p\"; uci -q get wireless.default_radio0.ssid; sysupgrade -l | grep -c '^/etc/board.json$'" | tr '\n' ' ')
hw=$(rw 'echo ok')
log "before: $pre; ssh over WAN: $hw"
echo "$a0" | grep -q '^reply from 52:54:00:50:00:01 untagged$' && ! echo "$a1" | grep -q '^reply' && [ "$pre" = "no-switch eth0 $SSID 1 " ] && [ "$hw" = ok ] \
  && res F2-E-before PASS "old-style state: no switch section, br-lan ports eth0, AP in default_radio0, board.json kept by sysupgrade.conf; LAN answers untagged ARP only; ssh over WAN ok" \
  || res F2-E-before FAIL "pre=$pre arp0=$a0 arp1=$a1 wan=$hw"
r "cat > /tmp/fw.img.gz" < $VB
sl=$(sha256sum < $VB | cut -d' ' -f1); sg=$(r "sha256sum /tmp/fw.img.gz | cut -d' ' -f1")
t=$(r "sysupgrade -T /tmp/fw.img.gz >/dev/null 2>&1 && echo test-ok")
log "variant B: sha256 local $sl guest $sg; sysupgrade -T: $t"
BID=$(rw "cat /proc/sys/kernel/random/boot_id")
r "sysupgrade /tmp/fw.img.gz </dev/null >/dev/null 2>&1 &" >/dev/null
waitdown 90; d=$?
waitsshw 90; u=$?
sleep 25
bid=$(rw "cat /proc/sys/kernel/random/boot_id")
rw "logread | grep -E 'bench: F2|switch|swconfig' | head; uci show network; uci show wireless | grep -E 'wifi-iface|ssid|encryption|disabled'; ls /sys/class/net/br-lan/brif; cat /proc/net/vlan/config; ls /etc/uci-defaults | wc -l; cat /etc/fw-variant" | tee -a $OUT
post=$(rw "cat /etc/fw-variant; uci -q get network.@switch[0].name; uci -q get network.@switch[0].reset; uci -q get network.@switch[0].enable_vlan
  uci -q get network.@switch_vlan[0].device; uci -q get network.@switch_vlan[0].vlan; uci -q get network.@switch_vlan[0].ports
  uci show network | sed -n \"s/.*@device\\[[0-9]*\\]\\.ports='\\(.*\\)'/\\1/p\"; uci -q get network.lan.ipaddr; ls /etc/uci-defaults | wc -l" | tr '\n' ' ')
lanst=$(rw "ifstatus lan | jsonfilter -e '@.up' -e '@[\"ipv4-address\"][0].address'" | tr '\n' ' ')
br=$(rw "ls /sys/class/net/br-lan/brif" | tr '\n' ' ')
lg=$(rw "logread | grep 'bench: F2:' | sed 's/.*bench: //'")
log "after: boot_id changed: $([ -n "$bid" ] && [ "$bid" != "$BID" ] && echo yes || echo no); config: $post; lan: $lanst; br-lan: $br; log: $lg"
[ "$sl" = "$sg" ] && [ "$t" = test-ok ] && [ $d = 0 ] && [ $u = 0 ] && [ -n "$bid" ] && [ "$bid" != "$BID" ] \
  && [ "$post" = "B switch0 1 1 switch0 1 1 2 3 4 0t eth0.1 $IP 0 " ] && [ "$lanst" = "true $IP " ] \
  && echo " $br" | grep -q " eth0.1 " && ! echo " $br" | grep -q " eth0 " && [ "$lg" = "F2: br-lan eth0 to eth0.1, switch switch0" ] \
  && res F2-E-migrate PASS "keep-settings sysupgrade to variant B: switch0 reset 1 enable_vlan 1, switch_vlan 1 ports '1 2 3 4 0t', br-lan ports eth0.1 (live: $(echo $br | tr ' ' ',')), lan up $IP, log '$lg', uci-defaults left 0" \
  || res F2-E-migrate FAIL "sha=$sl/$sg T=$t down=$d up=$u boot=$BID/$bid post=$post lan=$lanst br=$br log=$lg"
a0=$(arp 0); a1=$(arp 1)
log "after: untagged ARP: $a0; VLAN 1 ARP: $a1"
echo "$a1" | grep -q '^reply from 52:54:00:50:00:01 vid 1$' && ! echo "$a0" | grep -q '^reply' \
  && res F2-E-vlan PASS "LAN answers ARP tagged VLAN 1 ($a1) and not untagged: the layout the router's switch (CPU port 0t) needs" \
  || res F2-E-vlan FAIL "untagged: $a0; vlan 1: $a1"
for i in $(seq 1 30); do rw "ubus list hostapd.$AP" | grep -q $AP && break; sleep 2; done
wf=$(rw "uci -q get wireless.bench.ssid; uci -q get wireless.default_radio0 || echo no-default_radio0; cat /etc/benchweb/profile; iw dev $AP info | grep -c 'type AP'" | tr '\n' ' ')
wj=$(rw "REQUEST_METHOD=GET REMOTE_ADDR=$NET.10 HTTP_HOST=$IP /www-bench/cgi-bin/wifi | tail -n 1")
log "Wi-Fi after: $wf; GET /cgi-bin/wifi (CGI run in the guest): $wj"
[ "$wf" = "$SSID no-default_radio0 open 1 " ] && echo "$wj" | grep -q '"profile":"open","up":true' && echo " $br" | grep -q " $AP " \
  && res F2-E-wifi PASS "99-bench on upgrade renamed default_radio0 to bench and wrote profile open; AP up in br-lan; wifi CGI: $(echo "$wj" | cut -c1-80)" \
  || res F2-E-wifi FAIL "$wf / $wj / br=$br"
cp $RUN/console-e.log $W/logs/f2-console-e-${MEM}M.log
pkill -f qemu-system-mips
log "done"
