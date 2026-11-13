#!/bin/sh
# SPDX-License-Identifier: MIT
# Runs in the malta guest (disposable VM). Unit test of the F2 migration (/etc/uci-defaults/95-bench-switch)
# with sample network configs, using the router's board.json (captured from the router image's board.d scripts).
# Usage: f2-guest.sh SCRIPT ROUTER_BOARD_JSON [LAN_IP]   (LAN_IP: what 99-bench sets, default 192.168.1.1)
# Prints one line per case: F2-Un PASS|FAIL detail. /etc/config and /etc/board.json are restored at the end.
S=$1; RJ=$2; IP=${3:-192.168.1.1}
D=/tmp/f2w; rm -rf $D; mkdir -p $D
cp -a /etc/config $D/orig
cp /etc/board.json $D/malta.json
mount -t tmpfs tmpfs /etc/config
board() { umount /etc/board.json 2>/dev/null; mount --bind $1 /etc/board.json; }
# network config as config_generate writes it on a first boot with the current board.json, plus 99-bench's LAN address
gen() {
	rm -f /etc/config/*; cp $D/orig/system /etc/config/
	sh /bin/config_generate >/dev/null 2>&1
	uci set network.lan.ipaddr=$IP; uci set network.lan.netmask=255.255.255.0; uci commit network
}
# run the script as uci_apply_defaults does: sourced in a subshell
run() { ( cd /etc/uci-defaults 2>/dev/null; . "$S" ) > $D/out 2>&1; echo $?; }
# save NAME: the config file (NAME.cfg) and 'uci show' sorted (NAME, anonymous sections as @type[n], section order ignored)
save() { cp /etc/config/network $D/$1.cfg; uci show network | sort > $D/$1; }
res() { echo "$1 $2 $3"; }

board $D/malta.json; gen; save old          # image without board_name: generic layout, br-lan = eth0, no switch
board $RJ; gen; save stock                   # first boot of the fixed image: stock board layout
grep -q "ports='eth0'$" $D/old && ! grep -q '=switch$' $D/old && grep -q "ports='eth0.1'$" $D/stock && grep -q '@switch\[0\]=switch$' $D/stock \
	&& res F2-U0 PASS "samples: old = br-lan eth0, no switch; stock = br-lan eth0.1, switch0" || res F2-U0 FAIL "samples wrong: $(tr '\n' ' ' < $D/old)"

# U1: old config, router board.json -> stock layout, nothing else changed
board $RJ; cp $D/old.cfg /etc/config/network; n0=$(logread | grep -c 'bench: F2:')
rc=$(run); sleep 2; save u1; n1=$(logread | grep -c "bench: F2:")   # the script logs to /dev/kmsg; logd copies it
if cmp -s $D/u1 $D/stock && [ "$rc" = 0 ] && [ $((n1 - n0)) = 1 ]; then
	res F2-U1 PASS "old config -> same sections and options as config_generate's first-boot network (br-lan eth0.1, switch0 reset/enable_vlan 1, vlan 1 '1 2 3 4 0t', lan $IP, wan eth1); rc 0; log: $(logread | grep 'bench: F2:' | tail -n 1 | sed 's/.*bench: //')"
else
	res F2-U1 FAIL "rc=$rc log+$((n1 - n0)) got: $(tr '\n' ' ' < $D/u1) want: $(tr '\n' ' ' < $D/stock) out: $(tr '\n' ' ' < $D/out)"
fi
# U2: run again on the migrated config: no change
m0=$(md5sum < /etc/config/network); rc=$(run); sleep 2; m1=$(md5sum < /etc/config/network); n2=$(logread | grep -c "bench: F2:")
[ "$m0" = "$m1" ] && [ "$rc" = 0 ] && [ "$n2" = "$n1" ] && res F2-U2 PASS "second run on the migrated config: file unchanged, no log line" || res F2-U2 FAIL "rc=$rc changed=$([ "$m0" = "$m1" ] && echo no || echo yes)"
# U3: stock first-boot config: no change
cp $D/stock.cfg /etc/config/network; m0=$(md5sum < /etc/config/network); rc=$(run); m1=$(md5sum < /etc/config/network)
[ "$m0" = "$m1" ] && [ "$rc" = 0 ] && res F2-U3 PASS "stock first-boot config: unchanged" || res F2-U3 FAIL "rc=$rc"
# U4: board without a switch (malta's own board.json), old config: no change
board $D/malta.json; cp $D/old.cfg /etc/config/network; m0=$(md5sum < /etc/config/network); rc=$(run); m1=$(md5sum < /etc/config/network)
[ "$m0" = "$m1" ] && [ "$rc" = 0 ] && res F2-U4 PASS "board.json without a switch: unchanged" || res F2-U4 FAIL "rc=$rc"
# U5: router board.json, br-lan without plain eth0 (hand-made layout): no change
board $RJ; cp $D/old.cfg /etc/config/network
b=$(uci show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p"); uci del_list network.$b.ports=eth0; uci add_list network.$b.ports=eth9; uci commit network
m0=$(md5sum < /etc/config/network); rc=$(run); m1=$(md5sum < /etc/config/network)
[ "$m0" = "$m1" ] && [ "$rc" = 0 ] && res F2-U5 PASS "br-lan without plain eth0: unchanged" || res F2-U5 FAIL "rc=$rc"

umount /etc/board.json; umount /etc/config
cmp -s /etc/board.json $D/malta.json && [ "$(uci -q get network.lan.ipaddr)" = "$IP" ] && echo "restored" || echo "RESTORE FAILED"
