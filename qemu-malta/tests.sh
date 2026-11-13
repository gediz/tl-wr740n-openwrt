#!/bin/bash
# SPDX-License-Identifier: MIT
# QEMU malta test run. Runs inside container owrt-qemu-malta (started by run.sh with --network none).
# Usage: tests.sh [RAM_MB]   (default 32)
# Writes /work/logs/raw-<RAM>M.log (full output) and /work/logs/summary-<RAM>M.txt (one line per check).
MEM=${1:-32}
W=/work
IMG=$W/images
RUN=/tmp/run
OUT=$W/logs/raw-${MEM}M.log
SUM=$W/logs/summary-${MEM}M.txt
KEY=/keys/id_ed25519
RSA=/keys/id_rsa
IP=${LAN_IP:-192.168.1.1}; NET=${IP%.*}   # overlay values, passed in by the run-*.sh scripts (keys.inc.sh)
SSID=${WIFI_SSID:-wr740n}; HN=${ROUTER_HOSTNAME:-wr740n}
SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o IdentitiesOnly=yes"
AP=phy0-ap0

mkdir -p $RUN $W/logs
: > $OUT; : > $SUM
log() { echo "$*" | tee -a $OUT; }
res() { echo "$1 $2 $3" | tee -a $SUM | sed 's/^/RESULT /' >> $OUT; echo "RESULT $1 $2 $3"; }
r() { ssh $SSHO -i $KEY root@$IP "$@" 2>&1; }
rl() { log "## guest: $*"; r "$@" | tee -a $OUT; }

# ---------- private network inside this container's own netns ----------
ip link show br0 >/dev/null 2>&1 || {
  ip link add br0 type bridge
  ip addr add $NET.2/24 dev br0
  ip tuntap add tap0 mode tap
  ip link set tap0 master br0
  ip link add vc0 type veth peer name vc1
  ip link set vc1 master br0
  for i in br0 tap0 vc0 vc1 lo; do ip link set $i up; done
}

# ---------- boot ----------
pkill -f qemu-system-mips; sleep 1
zcat -f $IMG/rootfs-ext4.img > $RUN/rootfs.ext4   # fresh copy: every run is a first boot
tr '\0' '\377' < /dev/zero | head -c 1048576 > $RUN/mtd.img   # erased flash for T9 (block2mtd + JFFS2)
log "# qemu-system-mips -M malta -cpu 24Kc -m ${MEM}M"
qemu-system-mips -M malta -cpu 24Kc -m ${MEM}M -nographic -vga none -monitor none \
  -serial file:$RUN/console.log \
  -kernel $IMG/vmlinux.elf -append "root=/dev/sda rootwait console=ttyS0" \
  -drive file=$RUN/rootfs.ext4,format=raw,if=ide \
  -drive file=$RUN/mtd.img,format=raw,if=ide,index=1 \
  -nic tap,ifname=tap0,script=no,downscript=no,model=pcnet,mac=52:54:00:50:00:01 \
  -nic user,model=pcnet,mac=52:54:00:50:00:02,net=10.0.2.0/24,hostfwd=tcp:127.0.0.1:2222-10.0.2.15:22 \
  </dev/null >$RUN/qemu.out 2>&1 &
QPID=$!
T0=$(date +%s)
up=0
for i in $(seq 1 120); do
  sleep 5
  kill -0 $QPID 2>/dev/null || break
  r true >/dev/null 2>&1 && { up=1; break; }
done
BOOT=$(( $(date +%s) - T0 ))
cp $RUN/console.log $W/logs/console-${MEM}M.log
if [ $up != 1 ]; then
  log "boot failed after ${BOOT}s"; tail -40 $RUN/console.log | tee -a $OUT
  res T1 FAIL "no ssh after ${BOOT}s at ${MEM}M"
  pkill -f qemu-system-mips; exit 1
fi
sleep 20   # let first-boot services settle
cp $RUN/console.log $W/logs/console-${MEM}M.log

# ---------- T1 boot + uci-defaults ----------
log "== T1 boot, uci-defaults"
rl "cat /etc/openwrt_release | grep DESCRIPTION; uname -a; cat /proc/cpuinfo | grep -m2 -E 'cpu model|system type'; uptime"
rl "uci get network.lan.ipaddr; uci get system.@system[0].hostname; cat /proc/sys/kernel/hostname; uci show dropbear | grep -i pass; ls /etc/uci-defaults/; ip -4 addr show br-lan | grep inet"
lan=$(r "uci get network.lan.ipaddr"); hn=$(r "cat /proc/sys/kernel/hostname"); left=$(r "ls /etc/uci-defaults/ | wc -l")
[ "$lan" = "$IP" ] && [ "$hn" = "$HN" ] && [ "$left" = 0 ] \
  && res T1 PASS "booted in ${BOOT}s at ${MEM}M; lan=$lan hostname=$hn uci-defaults left=$left" \
  || res T1 FAIL "lan=$lan hostname=$hn uci-defaults left=$left"

# ---------- T8 first-boot Wi-Fi (no configuration step) ----------
# 99-bench (files-bench) turns radio0 on at first boot: open SSID $WIFI_SSID, channel 1, country $WIFI_COUNTRY, network lan.
# Nothing below changes the config: the AP must already be up, bridged into br-lan, and accept a STA.
log "== T8 first-boot Wi-Fi"
for i in $(seq 1 30); do r "ubus list hostapd.$AP" | grep -q $AP && break; sleep 2; done
rl "uci show wireless | grep -E 'radio0\.(band|channel|htmode|country|disabled)|(bench|default_radio0)\.(ssid|encryption|network|mode|device)'; iw dev $AP info | grep -E 'ssid|type|channel'; ls /sys/class/net/br-lan/brif; grep -E '^(ssid|channel|country_code|hw_mode|bridge)=' /var/run/hostapd-phy0.conf"
ap=$(r "iw dev $AP info"); br=$(r "ls /sys/class/net/br-lan/brif | tr '\n' ' '")
# lan must be up with its address and eth0 must be a br-lan port: on the broken-VLAN-filter kernel hostapd makes a bare
# br-lan with only phy0-ap0 and the rest of T8 still passes (logs/vlanfilter-scripts/README.md).
lanst=$(r "ifstatus lan | jsonfilter -e '@.up' -e '@[\"ipv4-address\"][0].address' | tr '\n' ' '")
# 99-bench puts the AP in wireless.bench (the section the web UI manages), not default_radio0
sec=$(r "uci -q get wireless.bench.ssid; uci -q get wireless.bench.device; uci -q get wireless.default_radio0 || echo no-default_radio0" | tr '\n' ' ')
r "iw dev sta0 del 2>/dev/null; iw phy phy1 interface add sta0 type managed
   printf 'ctrl_interface=/var/run/wpa_sta\nnetwork={\n ssid=\"$SSID\"\n key_mgmt=NONE\n}\n' > /tmp/sta.conf
   wpa_supplicant -B -D nl80211 -i sta0 -c /tmp/sta.conf -P /tmp/sta.pid" >/dev/null
st=""; for i in $(seq 1 30); do st=$(r "wpa_cli -p /var/run/wpa_sta -i sta0 status"); echo "$st" | grep -q wpa_state=COMPLETED && break; sleep 2; done
echo "$st" | grep -E 'wpa_state|key_mgmt|ssid=|freq' | tee -a $OUT
sm=$(r "cat /sys/class/net/sta0/address"); cl=$(r "ubus call hostapd.$AP get_clients | grep -c '\"$sm\"'")
log "AP: $(echo "$ap" | grep -E 'ssid|type|channel' | tr -s '\t\n' '  '); br-lan ports: $br; STA $sm listed by hostapd: $cl"
echo "$ap" | grep -q 'type AP' && echo "$ap" | grep -q "ssid $SSID" && echo "$ap" | grep -q 'channel 1 (2412 MHz)' \
  && echo " $br" | grep -q " $AP " && echo " $br" | grep -q " eth0 " && [ "$lanst" = "true $IP " ] \
  && [ "$sec" = "$SSID radio0 no-default_radio0 " ] \
  && echo "$st" | grep -q wpa_state=COMPLETED && echo "$st" | grep -q 'key_mgmt=NONE' && [ "$cl" = 1 ] \
  && res T8 PASS "first boot, no config step: AP $AP up (ssid $SSID, open, channel 1 / 2412 MHz), uci section wireless.bench (no default_radio0), in br-lan with $(echo $br | tr ' ' ','); lan up=$(echo $lanst | tr ' ' /); STA connected key_mgmt=NONE freq=$(echo "$st" | sed -n 's/^freq=//p'), listed by hostapd" \
  || res T8 FAIL "ap=$(echo "$ap" | tr -s '\t\n' '  ') br=$br lan=$lanst uci=$sec sta=$(echo "$st" | sed -n 's/^wpa_state=//p') clients=$cl"
r "kill \$(cat /tmp/sta.pid); sleep 1; iw dev sta0 del" >/dev/null

# ---------- T10 board name (/tmp/sysinfo/board_name) ----------
# /lib/preinit/02_sysinfo fills it with 'strings /proc/device-tree/compatible | head -1'. Without the busybox strings
# applet it stays empty, and on the router sysupgrade's image metadata check then refuses every image (verify F1).
log "== T10 board name"
rl "command -v strings; cat /tmp/sysinfo/board_name /tmp/sysinfo/model; tr '\\0' '\\n' < /proc/device-tree/compatible; . /lib/functions.sh; board_name"
sb=$(r "command -v strings"); bn=$(r "cat /tmp/sysinfo/board_name"); dt=$(r "tr '\\0' '\\n' < /proc/device-tree/compatible | head -n 1")
fn=$(r ". /lib/functions.sh; board_name"); sx=$(r "strings /proc/device-tree/compatible | head -n 1")
[ -n "$sb" ] && [ -n "$bn" ] && [ "$bn" = "$dt" ] && [ "$fn" = "$bn" ] && [ "$sx" = "$dt" ] \
  && res T10 PASS "strings applet at $sb; /tmp/sysinfo/board_name='$bn' = first DT compatible; board_name() gives '$fn'" \
  || res T10 FAIL "strings='$sb' board_name='$bn' dt='$dt' board_name()='$fn' strings-out='$sx'"

# ---------- T9 overlayfs on xattr-capable upper layers ----------
# The router's overlay upper is tmpfs on first boot, then JFFS2. With JFFS2_FS_XATTR/TMPFS_XATTR off, overlayfs
# mounts without xattrs and rmdir of a lower-layer directory or mkdir over its whiteout fail with EIO.
# Here: tmpfs upper, and JFFS2 upper on block2mtd over the second IDE disk (erased, 1 MiB, 64 KiB blocks).
log "== T9 overlayfs xattr"
ovl() {  # $1 = label, $2 = upper base dir (mounted)
  r "set -e; L=/tmp/ovl-low; M=/tmp/ovl-m; U=$2
     rm -rf \$L; mkdir -p \$L/d1/sub \$L/d2 \$M; echo a > \$L/d1/sub/f; echo b > \$L/d2/f
     mkdir -p \$U/up \$U/wk; mount -t overlay ovl-$1 -o lowerdir=\$L,upperdir=\$U/up,workdir=\$U/wk \$M
     rm -rf \$M/d1; echo rmdir=ok
     mkdir \$M/d1; echo mkdir-over-whiteout=ok entries=\$(ls -A \$M/d1 | wc -l)
     mv \$M/d2 \$M/d2new; echo rename=ok d2new/f=\$(cat \$M/d2new/f) d2=\$([ -e \$M/d2 ] && echo present || echo gone)
     umount \$M; mount -t overlay ovl-$1 -o lowerdir=\$L,upperdir=\$U/up,workdir=\$U/wk \$M
     echo remount: d1-entries=\$(ls -A \$M/d1 | wc -l) d2=\$([ -e \$M/d2 ] && echo present || echo gone) d2new/f=\$(cat \$M/d2new/f)
     umount \$M" 2>&1
}
rl "dmesg -c >/dev/null; mkdir -p /tmp/ovl-t; mount -t tmpfs ovt /tmp/ovl-t; grep ovl-t /proc/mounts"
o1=$(ovl tmpfs /tmp/ovl-t); log "$o1"
rl "ls /dev/sdb && echo /dev/sdb,65536 > /sys/module/block2mtd/parameters/block2mtd; cat /proc/mtd"
n=$(r "sed -n 's/^mtd\([0-9]*\):.*block2mtd: \/dev\/sdb.*/\1/p' /proc/mtd")
rl "mkdir -p /tmp/ovl-j; { mount -t jffs2 /dev/mtdblock$n /tmp/ovl-j || mount -t jffs2 mtd$n /tmp/ovl-j; } && grep ovl-j /proc/mounts"
o2=$(ovl jffs2 /tmp/ovl-j); log "$o2"
dm=$(r "dmesg | grep -iE 'overlayfs|jffs2' | grep -viE 'Empty flash|erase|cleanmarker' | head -5"); log "dmesg: $dm"
r "umount /tmp/ovl-j /tmp/ovl-t" >/dev/null
want='rmdir=ok
mkdir-over-whiteout=ok entries=0
rename=ok d2new/f=b d2=gone
remount: d1-entries=0 d2=gone d2new/f=b'
[ "$o1" = "$want" ] && [ "$o2" = "$want" ] && ! echo "$dm" | grep -qi 'overlayfs.*xattr' && echo "$dm" | grep -q 'jffs2_build_xattr_subsystem' \
  && res T9 PASS "tmpfs and JFFS2 (block2mtd) upper: rm -rf of a lower-layer dir, mkdir over its whiteout (empty, opaque), mv of a lower-layer dir; same after remount; JFFS2 built its xattr subsystem, no overlayfs xattr warning" \
  || res T9 FAIL "tmpfs: $(echo $o1) / jffs2 (mtd$n): $(echo $o2) / dmesg: $(echo $dm)"

# ---------- T2 ssh ----------
log "== T2 ssh"
e=$(ssh $SSHO -i $KEY root@$IP 'echo ok-ed25519' 2>&1)
ssh $SSHO -i $KEY -v root@$IP true 2>&1 | grep -E 'Server accepts key|Authenticated' | tee -a $OUT
rr=$(ssh $SSHO -i $RSA root@$IP 'echo ok-rsa' 2>&1)
ssh $SSHO -i $RSA -v root@$IP true 2>&1 | grep -E 'Server accepts key|Authenticated' | tee -a $OUT
pw=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o PubkeyAuthentication=no \
     -o PreferredAuthentications=password,keyboard-interactive -v root@$IP true 2>&1 | grep -E 'Authentications that can continue|Permission denied' | sort -u)
log "ed25519: $e"; log "rsa: $rr"; log "password attempt: $pw"
[ "$e" = ok-ed25519 ] && res T2a PASS "ed25519 key login: $e" || res T2a FAIL "$e"
if [ ! -r $RSA ]; then res T2b SKIP "no RSA key mounted (SSH_KEY_RSA)"; elif [ "$rr" = ok-rsa ]; then res T2b PASS "RSA key login: $rr"; else res T2b FAIL "$rr"; fi
echo "$pw" | grep -q 'Permission denied (publickey)' && ! echo "$pw" | grep -q password \
  && res T2c PASS "password refused, server offers only: $(echo "$pw" | grep -m1 continue | sed 's/.*continue: //')" \
  || res T2c FAIL "$pw"
# user-mode NIC with hostfwd: give WAN (eth1) the slirp address, then ssh through 127.0.0.1:2222
r "uci set network.wan.proto=static; uci set network.wan.ipaddr=10.0.2.15; uci set network.wan.netmask=255.255.255.0; uci commit network; ifup wan" >/dev/null
sleep 5
hf=$(ssh $SSHO -i $KEY -p 2222 root@127.0.0.1 'echo ok-hostfwd' 2>&1)
log "hostfwd: $hf"
[ "$hf" = ok-hostfwd ] && res T2d PASS "ssh via user-mode NIC hostfwd 127.0.0.1:2222 -> 10.0.2.15:22" || res T2d FAIL "$hf"

# ---------- T3 dnsmasq / DHCP ----------
log "== T3 dnsmasq"
rl "pgrep -a dnsmasq || ps w | grep [d]nsmasq; netstat -lnu 2>/dev/null | grep -E ':(53|67) '; grep -E 'dhcp-range|interface' /var/etc/dnsmasq.conf.* "
cat > $RUN/udhcpc.sh <<'EOF'
#!/bin/sh
[ "$1" = bound ] && echo "BOUND ip=$ip mask=$subnet router=$router dns=$dns serverid=$serverid lease=$lease"
exit 0
EOF
chmod +x $RUN/udhcpc.sh
d=$(busybox udhcpc -i vc0 -f -q -n -t 5 -T 3 -s $RUN/udhcpc.sh 2>&1)
log "$d"
rl "cat /tmp/dhcp.leases; logread | grep -E 'DHCP(OFFER|ACK)' | tail -2"
b=$(echo "$d" | grep BOUND)
echo "$b" | grep -q "serverid=$IP" && res T3 PASS "client on private bridge got lease: $b" || res T3 FAIL "$d"

# ---------- T4 netem ----------
log "== T4 netem"
p0=$(ping -c 50 -i 0.2 -q $IP | tail -2 | tr '\n' ' ')
log "baseline: $p0"
rl "tc qdisc add dev eth0 root netem delay 100ms loss 10%; tc qdisc show dev eth0"
p1=$(ping -c 100 -i 0.2 -W 2 -q $IP | tail -2 | tr '\n' ' ')
log "netem: $p1"
rl "tc qdisc del dev eth0 root; tc qdisc show dev eth0"
p2=$(ping -c 20 -i 0.2 -q $IP | tail -2 | tr '\n' ' ')
log "after removal: $p2"
avg() { echo "$1" | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p'; }
loss() { echo "$1" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p'; }
a0=$(avg "$p0"); a1=$(avg "$p1"); a2=$(avg "$p2"); l1=$(loss "$p1")
awk -v a0=$a0 -v a1=$a1 -v l=$l1 'BEGIN{exit !((a1-a0)>80 && l>=2 && l<=25)}' \
  && res T4 PASS "rtt avg ${a0}ms -> ${a1}ms with netem (loss ${l1}%) -> ${a2}ms after del" \
  || res T4 FAIL "rtt $a0 -> $a1 loss $l1"

# ---------- T5 iperf3, tcpdump, ethtool, mdio ----------
log "== T5 tools"
rl "iperf3 -s -D; sleep 1; iperf3 -c 127.0.0.1 -t 3 | tail -4"
lo=$(r "iperf3 -c 127.0.0.1 -t 3" | grep -m1 sender | awk '{print $(NF-3), $(NF-2)}')
nl=$(iperf3 -c $IP -t 5 2>&1 | tee -a $OUT | grep -m1 sender | awk '{print $(NF-3), $(NF-2)}')
log "iperf3 loopback: $lo; container->guest: $nl"
[ -n "$lo" ] && [ -n "$nl" ] && res T5a PASS "iperf3 loopback $lo, over tap $nl (TCG emulation, not hardware speed)" || res T5a FAIL "lo=$lo net=$nl"
# start tcpdump, wait until it is listening, then ping (a fixed sleep failed once when the host was busy)
r "rm -f /tmp/td.txt; (tcpdump -ni br-lan -c 5 icmp </dev/null > /tmp/td.txt 2>&1 &); for i in \$(seq 1 30); do grep -q listening /tmp/td.txt && break; sleep 1; done" >/dev/null
ping -c 20 -i 0.3 -q $IP >/dev/null
r "sleep 2; killall tcpdump 2>/dev/null; true" >/dev/null
rl "cat /tmp/td.txt"
n=$(r "grep -c 'ICMP echo' /tmp/td.txt")
[ "${n:-0}" -ge 5 ] && res T5b PASS "tcpdump-mini captured $n ICMP packets on br-lan" || res T5b FAIL "captured ${n}"
rl "ethtool eth0 | grep -E 'Speed|Duplex|Link detected'; ethtool -i eth0 | head -2"
et=$(r "ethtool -i eth0 | head -1")
echo "$et" | grep -q driver && res T5c PASS "ethtool: $et" || res T5c FAIL "$et"
rl "lsmod | grep -E 'mdio_netlink|sch_netem|mac80211_hwsim'; mdio 2>&1 | head -3"

# ---------- memory helper ----------
mem() {  # $1 = label
  log "### memory: $1"
  r "free; grep -E 'MemTotal|MemFree|MemAvailable|^Cached|Buffers|Slab|Shmem:' /proc/meminfo
     echo 'RSS_kB private_kB(RSS-shared) process'
     for d in /proc/[0-9]*; do n=\$(sed -n 's/^Name:\t//p' \$d/status 2>/dev/null); s=\$(sed -n 's/^VmRSS:[ \t]*\([0-9]*\).*/\1/p' \$d/status 2>/dev/null); p=\$(awk '{print (\$2-\$3)*4}' \$d/statm 2>/dev/null); [ -n \"\$s\" ] && echo \"\$s \$p \$n\"; done | sort -rn | head -20" | tee -a $OUT
}

# ---------- T6 Wi-Fi with mac80211_hwsim ----------
log "== T6 wifi"
rl "ls /sys/class/ieee80211/; iw dev; uci show wireless | grep -E 'radio[01]\.(path|band|channel|disabled)'"
r "uci set wireless.radio0.disabled=0; uci set wireless.radio0.channel=1; uci set wireless.radio0.band=2g; uci set wireless.radio0.htmode=HT20
   uci set wireless.radio1.disabled=1; uci -q delete wireless.bench; uci -q delete wireless.default_radio0; uci -q delete wireless.default_radio1; uci commit wireless" >/dev/null

STAMAC=""
wifi_case() {  # name encryption "extra uci" "sta network lines"
  local name=$1 enc=$2 extra=$3 sta=$4
  log "--- case $name (encryption=$enc $extra)"
  r "uci -q delete wireless.ap; uci set wireless.ap=wifi-iface; uci set wireless.ap.device=radio0; uci set wireless.ap.mode=ap
     uci set wireless.ap.network=lan; uci set wireless.ap.ssid=bench-$name; uci set wireless.ap.encryption=$enc
     uci set wireless.ap.key=hwsim-test-psk; $extra uci commit wireless; wifi" >/dev/null
  for i in $(seq 1 30); do r "ubus list hostapd.$AP" | grep -q $AP && r "iw dev $AP info" | grep -q 'type AP' && break; sleep 2; done
  rl "grep -E '^(wpa_key_mgmt|ieee80211w|ieee80211r|mobility_domain|ft_psk_generate_local|sae_require_mfp|ssid|channel)=' /var/run/hostapd-phy0.conf"
  r "[ -f /tmp/sta.pid ] && kill \$(cat /tmp/sta.pid); sleep 1; iw dev sta0 del 2>/dev/null; iw phy phy1 interface add sta0 type managed
     printf 'ctrl_interface=/var/run/wpa_sta\nsae_pwe=2\nnetwork={\n ssid=\"bench-$name\"\n $sta\n}\n' > /tmp/sta.conf
     wpa_supplicant -B -D nl80211 -i sta0 -c /tmp/sta.conf -P /tmp/sta.pid" >/dev/null
  local st=""
  for i in $(seq 1 30); do st=$(r "wpa_cli -p /var/run/wpa_sta -i sta0 status"); echo "$st" | grep -q wpa_state=COMPLETED && break; sleep 2; done
  echo "$st" | grep -E 'wpa_state|key_mgmt|pairwise|ssid=|freq' | tee -a $OUT
  rl "ubus call hostapd.$AP get_clients | grep -E '\"(auth|assoc|authorized|mfp)\"' | tr -d ' \n'; echo"
  STAMAC=$(echo "$st" | sed -n 's/^address=//p')
  local km=$(echo "$st" | sed -n 's/^key_mgmt=//p')
  echo "$st" | grep -q wpa_state=COMPLETED && res "T6-$name" PASS "connected=yes key_mgmt=$km" \
    || { r "logread | grep -iE 'hostapd|wpa_supplicant|sta0' | tail -15" | tee -a $OUT; res "T6-$name" FAIL "connected=no state=$(echo "$st" | sed -n 's/^wpa_state=//p')"; }
}
FT="uci set wireless.ap.ieee80211r=1; uci set wireless.ap.mobility_domain=4f57; uci set wireless.ap.ft_psk_generate_local=1;"
wifi_case psk2       psk2      ""                                    'key_mgmt=WPA-PSK\n psk="hwsim-test-psk"'
wifi_case sae        sae       "uci set wireless.ap.ieee80211w=2;"   'key_mgmt=SAE\n ieee80211w=2\n sae_password="hwsim-test-psk"'
wifi_case mixed-sae  sae-mixed "uci set wireless.ap.ieee80211w=1;"   'key_mgmt=SAE\n ieee80211w=2\n sae_password="hwsim-test-psk"'
wifi_case mixed-psk  sae-mixed "uci set wireless.ap.ieee80211w=1;"   'key_mgmt=WPA-PSK\n ieee80211w=1\n psk="hwsim-test-psk"'
wifi_case ft-psk     psk2      "$FT"                                 'key_mgmt=FT-PSK\n psk="hwsim-test-psk"'
wifi_case ft-sae     sae       "$FT uci set wireless.ap.ieee80211w=2;" 'key_mgmt=FT-SAE\n ieee80211w=2\n sae_password="hwsim-test-psk"'
wifi_case owe        owe       ""                                    'key_mgmt=OWE\n ieee80211w=2'
wifi_case open       none      ""                                    'key_mgmt=NONE'

log "== T6 hostapd ubus control (AP: open, STA connected)"
rl "ubus -v list hostapd.$AP | grep -E 'switch_chan|del_client'"
rl "ubus call hostapd.$AP switch_chan '{\"freq\":2437,\"bcn_count\":5}'; sleep 4; iw dev $AP info | grep channel; iw dev sta0 link | grep -E 'freq|Connected'"
ch=$(r "iw dev $AP info | grep channel"); sl=$(r "iw dev sta0 link | grep freq")
echo "$ch" | grep -q 'channel 6' && res T6-csa PASS "AP now: $(echo $ch | cut -d, -f1); STA link $(echo $sl)" || res T6-csa FAIL "$ch / $sl"
rl "ubus call hostapd.$AP del_client '{\"addr\":\"$STAMAC\",\"reason\":5,\"deauth\":true,\"ban_time\":15000}'"
sleep 8
k1=$(r "wpa_cli -p /var/run/wpa_sta -i sta0 status | grep wpa_state; logread | grep -E 'AP-STA-DISCONNECTED|deauthenticated' | tail -2")
log "8s after del_client (ban 15s): $k1"
st=""; for i in $(seq 1 25); do st=$(r "wpa_cli -p /var/run/wpa_sta -i sta0 status | grep wpa_state"); echo "$st" | grep -q COMPLETED && break; sleep 2; done
log "after ban expiry: $st"
echo "$k1" | grep -qE "AP-STA-DISCONNECTED|deauthenticated due to local deauth" && ! echo "$k1" | grep -q COMPLETED && echo "$st" | grep -q COMPLETED \
  && res T6-kick PASS "del_client deauthenticated the STA, kept out for the 15s ban ($(echo "$k1" | head -1)), then $st" \
  || res T6-kick FAIL "$k1 / $st"
rl "wifi down; sleep 3; iw dev | grep -c 'type AP'; ubus list | grep -c hostapd.$AP"
dn=$(r "iw dev | grep -c 'type AP'")
r "wifi up" >/dev/null
st=""; for i in $(seq 1 30); do st=$(r "wpa_cli -p /var/run/wpa_sta -i sta0 status | grep wpa_state"); echo "$st" | grep -q COMPLETED && break; sleep 2; done
upc=$(r "iw dev | grep -c 'type AP'")
log "down: AP ifaces=$dn, up: AP ifaces=$upc, STA $st"
[ "$dn" = 0 ] && [ "$upc" = 1 ] && echo "$st" | grep -q COMPLETED && res T6-downup PASS "wifi down -> 0 AP ifaces, wifi up -> 1, STA reconnected" || res T6-downup FAIL "down=$dn up=$upc $st"

# ---------- T7 memory ----------
log "== T7 memory"
# device-like state: AP up (psk2), test STA stopped, uhttpd stopped
r "kill \$(cat /tmp/sta.pid); iw dev sta0 del; killall iperf3; /etc/init.d/uhttpd stop
   uci set wireless.ap.encryption=psk2; uci -q delete wireless.ap.ieee80211r; uci commit wireless; wifi" >/dev/null
sleep 15
mem "idle, AP up (psk2), dnsmasq, dropbear"
r "iperf3 -s -D" >/dev/null; sleep 1
iperf3 -c $IP -t 20 > $RUN/ip.txt 2>&1 &
IPID=$!; sleep 10; mem "during iperf3 (container -> guest, TCP)"; wait $IPID
grep -E 'sender|receiver' $RUN/ip.txt | tee -a $OUT
r "killall iperf3" >/dev/null
# web server question: uhttpd serving a static page
r "echo '<html><body>malta test ok</body></html>' > /www/index.html; /etc/init.d/uhttpd start; ls -l /www" | tee -a $OUT; sleep 3
mem "uhttpd started, idle"
WP=""; for j in 1 2 3 4; do (for i in $(seq 1 50); do busybox wget -q -O /dev/null http://$IP/ 2>/dev/null; done) & WP="$WP $!"; done
sleep 5; mem "uhttpd under 4 parallel wget loops"; wait $WP
log "wget ok count check:"; busybox wget -q -O - http://$IP/ | head -c 200 | tee -a $OUT; echo
res T7 INFO "see raw log memory sections"

pkill -f qemu-system-mips
cp $RUN/console.log $W/logs/console-${MEM}M.log
log "done"
