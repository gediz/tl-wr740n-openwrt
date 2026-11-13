#!/bin/bash
# SPDX-License-Identifier: MIT
# Web UI / HTTP API tests (W1 to W18, S1 to S9). Runs inside container owrt-qemu-web (started by run-web.sh, --network none).
# Usage: tests-web.sh [RAM_MB]   (default 32)
# Writes /work/logs/web-raw-<RAM>M.log and /work/logs/web-summary-<RAM>M.txt. The web password is never printed.
MEM=${1:-32}
W=/work
IMG=$W/images-web
RUN=/tmp/runweb
OUT=$W/logs/web-raw-${MEM}M.log
SUM=$W/logs/web-summary-${MEM}M.txt
KEY=/keys/id_ed25519
IP=${LAN_IP:-192.168.1.1}; NET=${IP%.*}   # overlay values, passed in by the run-*.sh scripts (keys.inc.sh)
SSID=${WIFI_SSID:-wr740n}; HN=${ROUTER_HOSTNAME:-wr740n}
U=http://$IP
SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o IdentitiesOnly=yes"
AP=phy0-ap0

mkdir -p $RUN $W/logs
: > $OUT; : > $SUM
log() { echo "$*" | tee -a $OUT; }
res() { echo "$1 $2 $3" | tee -a $SUM | sed 's/^/RESULT /' >> $OUT; echo "RESULT $1 $2 $3"; }
r() { ssh $SSHO -i $KEY root@$IP "$@" 2>&1; }
rl() { log "## guest: $*"; r "$@" | tee -a $OUT; }
# hc ARGS: authenticated curl, body to $RUN/body, prints the HTTP code
hc() { curl -s -m 120 -o $RUN/body -w '%{http_code}' -u "bench:$PW" "$@"; }
body() { tr -d '\r' < $RUN/body | head -c 600; }
# jchk EXPR: python check on $RUN/body as JSON 'j'; prints value, exit status = truth
jchk() { python3 -c "import json,sys; j=json.load(open('$RUN/body')); v=($1); print(v); sys.exit(0 if v else 1)" 2>&1; }
ok() { [ "$2" = PASS ] || [ "$2" = FAIL ]; }
waitssh() { for i in $(seq 1 ${1:-60}); do sleep 5; r true >/dev/null 2>&1 && return 0; done; return 1; }
# hcode ARGS: plain curl (own -u), prints the HTTP code, body to $RUN/body
hcode() { curl -s -m 60 -o $RUN/body -w '%{http_code}' "$@"; }
# guest helper: lowest pid of each daemon (masters, not per-connection children)
pids() { r 'for n in procd ubusd logd netifd dnsmasq dropbear hostapd wpa_supplicant; do echo "$n $(pidof $n | tr " " "\n" | sort -n | head -n 1)"; done'; }
waitdown() { for i in $(seq 1 ${1:-60}); do r true >/dev/null 2>&1 || return 0; sleep 2; done; return 1; }

ip link show br0 >/dev/null 2>&1 || {
  ip link add br0 type bridge
  ip addr add $NET.2/24 dev br0
  ip tuntap add tap0 mode tap
  ip link set tap0 master br0
  ip link add vc0 type veth peer name vc1
  ip link set vc1 master br0
  for i in br0 tap0 vc0 vc1 lo; do ip link set $i up; done
}

cat > $RUN/mk.py <<'EOF'
# mk.py OUT KIND: crafted restore archives (each also carries etc/uci-defaults/99-sec)
import tarfile, io, sys
out, kind = sys.argv[1], sys.argv[2]
t = tarfile.open(out, "w:gz")
def add(name, data=b"", **kw):
    ti = tarfile.TarInfo(name)
    for k, v in kw.items(): setattr(ti, k, v)
    if ti.type == tarfile.REGTYPE: ti.size = len(data); t.addfile(ti, io.BytesIO(data))
    else: t.addfile(ti)
add("etc/uci-defaults/99-sec", b"#!/bin/sh\ntouch /tmp/sec-ucidefaults\nexit 0\n", mode=0o755)
if kind == "symlink":
    add("etc/zz", type=tarfile.SYMTYPE, linkname="/www-bench")
    add("etc/zz/pwn.txt", b"x\n", mode=0o644)
elif kind == "hardlink":
    add("etc/hl", type=tarfile.LNKTYPE, linkname="etc/uci-defaults/99-sec")
elif kind == "dotdot":
    add("etc/..", type=tarfile.DIRTYPE, mode=0o777)
elif kind == "fifo":
    add("etc/ff", type=tarfile.FIFOTYPE)
t.close()
EOF
cat > $RUN/slow.py <<'EOF'
# slow.py PW PATH SECONDS: authenticated upload headers with Content-Length 200000, 2 body bytes, then hold
import socket, sys, time, base64
pw, path, hold = sys.argv[1], sys.argv[2], int(sys.argv[3])
a = base64.b64encode(("bench:" + pw).encode()).decode()
IP = __import__("os").environ.get("LAN_IP", "192.168.1.1")
c = socket.create_connection((IP, 80))
c.send(("POST %s HTTP/1.1\r\nHost: %s\r\nAuthorization: Basic %s\r\nContent-Type: application/octet-stream\r\nContent-Length: 200000\r\n\r\n" % (path, IP, a)).encode() + b"\x1f\x8b")
c.settimeout(hold); t0 = time.time(); d = b""
try:
    while True:
        x = c.recv(4096)
        if not x: break
        d += x
    print("reply after %.0f s: %s" % (time.time() - t0, d.decode(errors="replace").split("\r\n\r\n")[-1].strip()))
except socket.timeout:
    print("no reply in %d s" % hold)
EOF
cat > $RUN/flood.py <<'EOF'
# flood.py N SECONDS: open N connections without credentials, send a partial request header, hold
import socket, sys, time
n, hold = int(sys.argv[1]), int(sys.argv[2]); s = []
IP = __import__("os").environ.get("LAN_IP", "192.168.1.1")
for i in range(n):
    try:
        c = socket.create_connection((IP, 80), timeout=5); c.send(b"GET / HTTP/1.1\r\nHost: x\r\n"); s.append(c)
    except Exception as e:
        print("connect refused at", i, e); break
print("open", len(s)); sys.stdout.flush()
time.sleep(hold)
EOF

pkill -f qemu-system-mips; sleep 1
zcat -f $IMG/openwrt-malta-be-rootfs-ext4.img.gz > $RUN/rootfs.ext4
log "# qemu-system-mips -M malta -cpu 24Kc -m ${MEM}M (web image)"
qemu-system-mips -M malta -cpu 24Kc -m ${MEM}M -nographic -vga none -monitor none \
  -serial file:$RUN/console.log \
  -kernel $IMG/vmlinux.elf -append "root=/dev/sda rootwait console=ttyS0" \
  -drive file=$RUN/rootfs.ext4,format=raw,if=ide \
  -nic tap,ifname=tap0,script=no,downscript=no,model=pcnet,mac=52:54:00:50:00:01 \
  -nic user,model=pcnet,mac=52:54:00:50:00:02,net=10.0.2.0/24 \
  </dev/null >$RUN/qemu.out 2>&1 &
waitssh 120 || { log "boot failed"; tail -40 $RUN/console.log | tee -a $OUT; res W0 FAIL "no ssh"; exit 1; }
sleep 20
rl "cat /etc/openwrt_release | grep DESCRIPTION; ls -l /etc/benchweb; ls /etc/uci-defaults; pgrep -af httpd; netstat -lnt | grep ':80 '"
PW=$(r "cat /etc/benchweb/password")
log "password: ${#PW} chars read over ssh (not shown)"

# ---------- W1 auth ----------
log "== W1 auth"
a=$(curl -s -o /dev/null -w '%{http_code}' $U/cgi-bin/status)
a2=$(curl -s -o /dev/null -w '%{http_code}' $U/)
b=$(curl -s -o /dev/null -w '%{http_code}' -u bench:wrong $U/cgi-bin/status)
b2=$(curl -s -o /dev/null -w '%{http_code}' -u root:"$PW" $U/cgi-bin/status)
c=$(hc $U/cgi-bin/status); c2=$(hc $U/)
bind=$(r "netstat -lnt | grep ':80 ' | awk '{print \$4}'")
log "no auth: status=$a /=$a2; wrong password=$b; wrong user=$b2; correct: status=$c /=$c2; listening on $bind"
[ "$a$a2$b$b2" = 401401401401 ] && [ "$c$c2" = 200200 ] && [ "$bind" = "$IP:80" ] \
  && res W1 PASS "no auth 401/401, wrong password 401, wrong user 401, correct 200/200; httpd bound to $bind only" \
  || res W1 FAIL "$a $a2 $b $b2 $c $c2 bind=$bind"

# ---------- W2 status JSON ----------
log "== W2 status"
c=$(hc $U/cgi-bin/status); body | tee -a $OUT; echo >> $OUT
v=$(jchk "all(k in j for k in ('uptime','load','mem_kb','firmware','kernel','lan_ip','ports','wifi','netem')) and j['mem_kb']['total']>0 and j['mem_kb']['available']>0 and len(j['load'])==3 and j['lan_ip']=='$IP' and 'profile' in j['wifi'] and set(j['netem'])=={'lan','wan','wlan'}")
[ "$c" = 200 ] && [ "$v" = True ] && res W2 PASS "valid JSON, all fields; $(jchk "'kernel %s, MemAvailable %s kB, ports %s, netem devs %s' % (j['kernel'], j['mem_kb']['available'], j['ports'], {k:[d['dev'] for d in x] for k,x in j['netem'].items()})")" \
  || res W2 FAIL "code=$c $v"

tar -czf $RUN/bk0.tgz -C $RUN mk.py   # S4: a body that must never be applied

# ---------- W16 first-boot Wi-Fi (no configuration step) ----------
# 99-bench turns the bench AP on at first boot (open, $WIFI_SSID, channel 1, lan). Before W3 changes anything:
# the AP must be up, bridged into br-lan, and accept a STA.
log "== W16 first-boot Wi-Fi"
for i in $(seq 1 30); do r "ubus list hostapd.$AP" | grep -q $AP && break; sleep 2; done
ap=$(r "iw dev $AP info"); br=$(r "ls /sys/class/net/br-lan/brif | tr '\n' ' '")
# lan must be up with its address and eth0 must be a br-lan port: on the broken-VLAN-filter kernel hostapd makes a bare
# br-lan with only phy0-ap0 and the rest of W16 still passes (logs/vlanfilter-scripts/README.md).
lanst=$(r "ifstatus lan | jsonfilter -e '@.up' -e '@[\"ipv4-address\"][0].address' | tr '\n' ' '")
# 99-bench puts the AP in wireless.bench, the section POST /cgi-bin/wifi manages, and records profile open (verify note W1)
sec=$(r "uci -q get wireless.bench.ssid; uci -q get wireless.default_radio0 || echo no-default_radio0; cat /etc/benchweb/profile" | tr '\n' ' ')
hc $U/cgi-bin/wifi >/dev/null; wp=$(jchk "j['profile']")
r "iw dev sta0 del 2>/dev/null; iw phy phy1 interface add sta0 type managed
   printf 'ctrl_interface=/var/run/wpa_sta\nnetwork={\n ssid=\"$SSID\"\n key_mgmt=NONE\n}\n' > /tmp/sta.conf
   wpa_supplicant -B -D nl80211 -i sta0 -c /tmp/sta.conf -P /tmp/sta.pid" >/dev/null
st=""; for i in $(seq 1 30); do st=$(r "wpa_cli -p /var/run/wpa_sta -i sta0 status"); echo "$st" | grep -q wpa_state=COMPLETED && break; sleep 2; done
hc $U/cgi-bin/clients >/dev/null; cj=$(body)
log "AP: $(echo "$ap" | grep -E 'ssid|type|channel' | tr -s '\t\n' '  '); br-lan ports: $br; STA: $(echo "$st" | grep -E 'wpa_state|key_mgmt|freq' | tr '\n' ' '); clients: $cj"
echo "$ap" | grep -q 'type AP' && echo "$ap" | grep -q "ssid $SSID" && echo "$ap" | grep -q 'channel 1 (2412 MHz)' \
  && echo " $br" | grep -q " $AP " && echo " $br" | grep -q " eth0 " && [ "$lanst" = "true $IP " ] \
  && [ "$sec" = "$SSID no-default_radio0 open " ] && [ "$wp" = open ] \
  && echo "$st" | grep -q wpa_state=COMPLETED && echo "$st" | grep -q 'key_mgmt=NONE' && echo "$cj" | grep -q "\"$AP\":\[{\"mac\"" \
  && res W16-firstboot-wifi PASS "AP $AP up at first boot ($SSID, open, 2412 MHz), uci wireless.bench, GET /cgi-bin/wifi profile=$wp, in br-lan ($(echo $br | tr ' ' ',')); lan up=$(echo $lanst | tr ' ' /); STA connected key_mgmt=NONE; /cgi-bin/clients lists it" \
  || res W16-firstboot-wifi FAIL "ap=$(echo "$ap" | tr -s '\t\n' '  ') br=$br lan=$lanst uci=$sec profile=$wp sta=$(echo "$st" | sed -n 's/^wpa_state=//p') clients=$cj"
r "kill \$(cat /tmp/sta.pid); sleep 1; iw dev sta0 del" >/dev/null

# ---------- W18 board name (/tmp/sysinfo/board_name) ----------
# /lib/preinit/02_sysinfo fills it with 'strings /proc/device-tree/compatible | head -1'. Without the busybox strings
# applet it stays empty, and on the router sysupgrade's image metadata check (and so POST /cgi-bin/upgrade) refuses
# every image (verify F1).
log "== W18 board name"
sb=$(r "command -v strings"); bn=$(r "cat /tmp/sysinfo/board_name"); dt=$(r "tr '\\0' '\\n' < /proc/device-tree/compatible | head -n 1")
fn=$(r ". /lib/functions.sh; board_name")
log "strings=$sb board_name=$bn dt-compatible=$dt board_name()=$fn"
[ -n "$sb" ] && [ -n "$bn" ] && [ "$bn" = "$dt" ] && [ "$fn" = "$bn" ] \
  && res W18-board-name PASS "strings applet at $sb; /tmp/sysinfo/board_name='$bn' = first DT compatible; board_name() gives '$fn'" \
  || res W18-board-name FAIL "strings='$sb' board_name='$bn' dt='$dt' board_name()='$fn'"

# ---------- W10a memory idle ----------
log "== W10 memory, idle"
memsnap() { r "grep -E 'MemTotal|MemFree|MemAvailable|^Cached|Shmem:' /proc/meminfo | tr -s ' ' | tr '\n' ' '; echo; for p in \$(pgrep httpd); do echo \"httpd pid \$p \$(grep VmRSS /proc/\$p/status | tr -s ' \t' ' ')\"; done; df -k /tmp | tail -1"; }
m0=$(memsnap); log "$m0"
MA0=$(echo "$m0" | sed -n 's/.*MemAvailable: \([0-9]*\).*/\1/p')

# ---------- W5 port (no switch in QEMU) ----------
log "== W5 port"
c1=$(hc $U/cgi-bin/port); b1=$(body); v1=$(jchk "j.get('error')=='no switch'")
c2=$(hc -d 'port=1&action=down' $U/cgi-bin/port); b2=$(body); v2=$(jchk "j.get('error')=='no switch'")
log "GET $c1 $b1 / POST $c2 $b2"
[ "$c1$c2" = 503503 ] && [ "$v1$v2" = TrueTrue ] && res W5 PASS "GET and POST port=1 action=down -> 503 $b2 (swconfig finds no switch)" || res W5 FAIL "$c1 $b1 $c2 $b2"

# ---------- W6 dhcp ----------
log "== W6 dhcp"
cat > $RUN/udhcpc.sh <<'EOF'
#!/bin/sh
[ "$1" = bound ] && echo "BOUND ip=$ip serverid=$serverid"
exit 0
EOF
chmod +x $RUN/udhcpc.sh
lease() { busybox udhcpc -i vc0 -f -q -n -t 4 -T 3 -s $RUN/udhcpc.sh 2>&1 | grep BOUND; }
l0=$(lease)
c1=$(hc -d action=off $U/cgi-bin/dhcp); b1=$(body); sleep 3
l1=$(lease)
c2=$(hc -d action=on $U/cgi-bin/dhcp); b2=$(body); sleep 3
l2=$(lease)
log "before: $l0 | off ($c1 $b1): '$l1' | on ($c2 $b2): $l2"
[ -n "$l0" ] && [ -z "$l1" ] && [ -n "$l2" ] && [ "$c1$c2" = 200200 ] \
  && res W6 PASS "lease before; off -> no lease (4 tries); on -> $l2" || res W6 FAIL "l0=$l0 l1=$l1 l2=$l2 $c1 $c2"

# ---------- W11 log ----------
log "== W11 log"
r "logger -t w11 'a\"b\\c end'" >/dev/null
c1=$(hc "$U/cgi-bin/log?n=10"); v1=$(jchk "isinstance(j, list) and len(j) == 10 and all(isinstance(x, str) for x in j)")
c2=$(hc "$U/cgi-bin/log?n=500"); n2=$(jchk "len(j)")
v2=$(jchk "any('benchweb' in x for x in j) and any(' kern.' in x for x in j)"); bw=$(jchk "[x for x in j if 'benchweb' in x][-1][25:]")
v3=$(python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print(any(x.endswith("w11: a\"b\\c end") for x in j))' $RUN/body)
bads=""; for q in n=9 n=501 n=abc n=-10 'n=10;id'; do bads="$bads $(hc "$U/cgi-bin/log?$q")"; done
m=$(hc -d n=10 $U/cgi-bin/log); cg=$(r "ls /www-bench/cgi-bin | tr '\n' ' '")
log "n=10: $c1 $v1; n=500: $c2, $n2 lines, benchweb+kernel $v2, last benchweb: $bw; quote/backslash line: $v3; bad n:$bads; POST $m; cgi-bin: $cg"
[ "$c1$c2" = 200200 ] && [ "$v1$v2$v3" = TrueTrueTrue ] && [ "$bads" = " 400 400 400 400 400" ] && [ "$m" = 405 ] \
  && [ "$cg" = "backup clients dhcp leases log netem ping port reboot reset restore status upgrade wifi " ] \
  && res W11-log PASS "n=10 -> 10 strings; n=500 -> $n2 lines incl. kernel and benchweb ('$bw'); a log line with \" and \\ parses back unchanged; n=9/501/abc/-10/'10;id' 400; POST 405; no stray files in cgi-bin" \
  || res W11-log FAIL "$c1 $v1 $c2 $v2 $v3 bad:$bads post:$m cgi:$cg"

# ---------- W12 leases ----------
log "== W12 leases"
mac=$(cat /sys/class/net/vc0/address)
lip=$(busybox udhcpc -i vc0 -f -q -n -t 4 -T 3 -x hostname:w12-client -s $RUN/udhcpc.sh 2>&1 | sed -n 's/.*BOUND ip=\([0-9.]*\).*/\1/p'); sleep 2
c=$(hc $U/cgi-bin/leases); b=$(body); v=$(jchk "[x for x in j if x['mac'] == '$mac' and x['ip'] == '$lip' and x['hostname'] == 'w12-client' and x['expiry'] > 0]")
m=$(hc -d x=1 $U/cgi-bin/leases); f=$(r "grep -c . /tmp/dhcp.leases")
log "client $mac got $lip; leases: $c $b; POST $m; lease file lines $f"
[ "$c" = 200 ] && [ -n "$lip" ] && [ "$v" != "[]" ] && echo "$v" | grep -q "$mac" && [ "$m" = 405 ] \
  && res W12-leases PASS "test client lease listed: $v ($f lease(s) in /tmp/dhcp.leases); POST 405" \
  || res W12-leases FAIL "$c lip=$lip $b post=$m"

# ---------- W14 ping ----------
log "== W14 ping"
r "rm -f /tmp/pwned" >/dev/null
c1=$(hc -d "host=$NET.2&count=3" $U/cgi-bin/ping); b1=$(body); v1=$(jchk "j['transmitted'] == 3 and j['received'] == 3 and j['loss_pct'] == 0 and j['rtt_ms']['min'] <= j['rtt_ms']['avg'] <= j['rtt_ms']['max']")
p1=$(jchk "'%d/%d received, loss %d%%, rtt %s' % (j['received'], j['transmitted'], j['loss_pct'], j['rtt_ms'])")
c2=$(hc -d "host=$NET.254&count=2" $U/cgi-bin/ping); b2=$(body); v2=$(jchk "j['received'] == 0 and j['loss_pct'] == 100 and j['rtt_ms'] is None")
c3=$(hc -d 'host=localhost&count=1' $U/cgi-bin/ping); b3=$(body); v3=$(jchk "j['received'] == 1")
log "$NET.2: $c1 $b1"; log "$NET.254: $c2 $b2"; log "localhost: $c3 $b3"
pf=""
pinj() { local c=$(hc "$@" $U/cgi-bin/ping); log "$c  $*  -> $(body)"; [ "$c" = 400 ] || pf="$pf [$*: $c]"; }
pinj -d 'host=1.1.1.1;id'
pinj --data-urlencode 'host=1.1.1.1;id'
pinj --data-urlencode 'host=1.1.1.1 -f' -d count=1
pinj --data-urlencode 'host=$(touch /tmp/pwned)'
pinj -d 'host=-f&count=1'
pinj -d 'host=-c&count=1'
pinj -d 'host=.x'
pinj -d 'host=a_b'
pinj -d 'host=256.1.1.1'
pinj -d 'host=1.2.3.4.5'
pinj -d 'host=1.2.3'
pinj -d "host=$(head -c 64 /dev/zero | tr '\0' a)"
pinj -d 'count=1'
pinj -d "host=$NET.2&count=0"
pinj -d "host=$NET.2&count=11"
pinj -d "host=$NET.2&count=1x"
g=$(hc "$U/cgi-bin/ping?host=$NET.2"); o=$(hc -H 'Origin: http://evil.example' -d "host=$NET.2" $U/cgi-bin/ping)
pw=$(r "ls /tmp/pwned 2>&1; logread | grep -c 'benchweb.*ping host='")
log "GET $g, cross-origin $o; guest: $(echo $pw)"
[ "$c1$c2$c3" = 200200200 ] && [ "$v1$v2$v3" = TrueTrueTrue ] && [ -z "$pf" ] && [ "$g$o" = 405403 ] && echo "$pw" | grep -q 'No such file' \
  && res W14-ping PASS "$NET.2 count=3: $p1; unused $NET.254: 100% loss, rtt null; localhost resolves; 16 bad inputs (incl. 'host=1.1.1.1;id', '-f', 256.1.1.1, 64 chars, count 0/11) 400; GET 405; cross-origin 403; /tmp/pwned absent" \
  || res W14-ping FAIL "$c1 $v1 $c2 $v2 $c3 $v3 inj:$pf get=$g origin=$o $(echo $pw)"

# ---------- W4 netem ----------
log "== W4 netem"
avg() { echo "$1" | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p'; }
loss() { echo "$1" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p'; }
p0=$(ping -c 20 -i 0.2 -q $IP | tail -2 | tr '\n' ' ')
c1=$(hc -d 'iface=lan&delay_ms=100&loss_pct=10' $U/cgi-bin/netem); b1=$(body)
t1=$(r "tc qdisc show dev eth0 root")
p1=$(ping -c 100 -i 0.2 -W 2 -q $IP | tail -2 | tr '\n' ' ')
c2=$(hc -d 'iface=lan&action=clear' $U/cgi-bin/netem); b2=$(body)
t2=$(r "tc qdisc show dev eth0 root")
p2=$(ping -c 20 -i 0.2 -q $IP | tail -2 | tr '\n' ' ')
log "set: $c1 $b1"; log "tc: $t1"; log "rtt: $p0 | $p1 | $p2"; log "clear: $c2 $b2"; log "tc: $t2"
a0=$(avg "$p0"); a1=$(avg "$p1"); a2=$(avg "$p2"); l1=$(loss "$p1")
echo "$t1" | grep -q 'netem.*delay 100ms loss 10%' && ! echo "$t2" | grep -q netem && [ "$c1$c2" = 200200 ] \
  && awk -v a0=$a0 -v a1=$a1 -v a2=$a2 -v l=$l1 'BEGIN{exit !((a1-a0)>80 && l>=2 && l<=25 && a2<20)}' \
  && res W4 PASS "tc: '$(echo $t1 | cut -c1-80)'; rtt ${a0} -> ${a1} ms (loss ${l1}%) -> ${a2} ms after clear" \
  || res W4 FAIL "c=$c1/$c2 tc=$t1 / $t2 rtt $a0 $a1 $a2 loss $l1"
# auto-clear
# t4 must be real tc output (an ssh error must not count as "no netem"): retry ssh up to 3 times
c3=$(hc -d 'iface=lan&delay_ms=50&for_s=5' $U/cgi-bin/netem); t3=$(r "tc qdisc show dev eth0 root"); sleep 9
for i in 1 2 3; do t4=$(r "tc qdisc show dev eth0 root"); echo "$t4" | grep -q '^qdisc ' && break; log "ssh try $i: $t4"; sleep 2; done
log "for_s=5: $c3 '$t3' -> after 9 s '$t4'"
echo "$t3" | grep -q 'delay 50ms' && echo "$t4" | grep -q '^qdisc ' && ! echo "$t4" | grep -q netem && res W4-autoclear PASS "delay 50ms with for_s=5 removed after 5 s, tc now: $(echo $t4 | cut -c1-40)" || res W4-autoclear FAIL "$t3 / $t4"
c5=$(hc -d 'iface=wan&delay_ms=20&loss_pct=0' $U/cgi-bin/netem); t5=$(r "tc qdisc show dev eth1 root"); hc -d 'iface=wan&action=clear' $U/cgi-bin/netem >/dev/null
r "wifi down" >/dev/null; sleep 3   # the first-boot AP is up and bridged: take it down for the no-AP case
c6=$(hc -d 'iface=wlan&delay_ms=20' $U/cgi-bin/netem); b6=$(body)
r "wifi up" >/dev/null
log "wan: $c5 $t5 / wlan (wifi down): $c6 $b6"
echo "$t5" | grep -q 'delay 20ms' && [ "$c6" = 409 ] && res W4-wan-wlan PASS "wan -> eth1 netem; wlan after wifi down (no AP) -> 409 $b6" || res W4-wan-wlan FAIL "$c5 $t5 $c6 $b6"

# ---------- W3 wifi profiles ----------
log "== W3 wifi"
SSID=$(r "sed -n 's/^ssid=//p' /etc/benchweb/wifi.conf"); WK=$(r "sed -n 's/^key=//p' /etc/benchweb/wifi.conf")
r "uci set wireless.radio0.band=2g; uci set wireless.radio0.htmode=HT20; uci set wireless.radio1.disabled=1; uci commit wireless" >/dev/null
sta() {  # $1 = network block lines
  r "[ -f /tmp/sta.pid ] && kill \$(cat /tmp/sta.pid); sleep 1; iw dev sta0 del 2>/dev/null; iw phy phy1 interface add sta0 type managed
     printf 'ctrl_interface=/var/run/wpa_sta\nsae_pwe=2\nnetwork={\n ssid=\"$SSID\"\n $1\n}\n' > /tmp/sta.conf
     wpa_supplicant -B -D nl80211 -i sta0 -c /tmp/sta.conf -P /tmp/sta.pid" >/dev/null
}
wcase() {  # profile channel "sta lines" [label]
  local p=$1 ch=$2 c st km n="W3-$1${4:+-$4}"
  c=$(hc -d "profile=$p${ch:+&channel=$ch}" $U/cgi-bin/wifi); log "--- $p: POST $c $(body)"
  # wait for the AP the profile set up (the first-boot AP has the same SSID, so a STA could catch the old one)
  sleep 3; for i in $(seq 1 20); do hc $U/cgi-bin/wifi >/dev/null; grep -q '"up":true' $RUN/body && break; sleep 2; done
  sta "$3"
  for i in $(seq 1 30); do st=$(r "wpa_cli -p /var/run/wpa_sta -i sta0 status"); echo "$st" | grep -q wpa_state=COMPLETED && break; sleep 2; done
  km=$(echo "$st" | sed -n 's/^key_mgmt=//p'); fq=$(echo "$st" | sed -n 's/^freq=//p')
  for i in $(seq 1 10); do hc $U/cgi-bin/wifi >/dev/null; grep -q '"up":true' $RUN/body && break; sleep 2; done
  log "GET: $(body)"
  rl "grep -E '^(wpa_key_mgmt|ieee80211w|ieee80211r|channel)=' /var/run/hostapd-phy0.conf | tr '\n' ' '; echo"
  echo "$st" | grep -q wpa_state=COMPLETED && [ "$c" = 200 ] && { [ -z "$ch" ] || [ "$fq" = $((2407 + 5 * ch)) ]; } && grep -q "\"profile\":\"$p\",\"up\":true" $RUN/body \
    && res "$n" PASS "connected key_mgmt=$km freq=$fq; GET $(jchk "'%s %s ch%s clients=%s' % (j['profile'], j['encryption'], j['channel'], j['clients'])")" \
    || res "$n" FAIL "code=$c state=$(echo "$st" | sed -n 's/^wpa_state=//p') km=$km freq=$fq"
}
P="psk=\"$WK\""; S="sae_password=\"$WK\""
wcase open   1 'key_mgmt=NONE'
wcase wpa2   6 "key_mgmt=WPA-PSK\n $P"
wcase wpa3   "" "key_mgmt=SAE\n ieee80211w=2\n $S"
wcase mixed  11 "key_mgmt=SAE\n ieee80211w=2\n $S" sae
wcase mixed  "" "key_mgmt=WPA-PSK\n $P" psk
wcase ft-psk "" "key_mgmt=FT-PSK\n $P"
wcase ft-sae "" "key_mgmt=FT-SAE\n ieee80211w=2\n $S"
wcase owe    1 'key_mgmt=OWE\n ieee80211w=2'
# status shows the client
hc $U/cgi-bin/status >/dev/null; v=$(jchk "j['wifi']['clients']==1 and j['wifi']['ssid']=='$SSID'")
log "status wifi: $(jchk "j['wifi']")"
[ "$v" = True ] && res W3-status PASS "status wifi: $(jchk "j['wifi']")" || res W3-status FAIL "$v"
# wlan netem now that the AP is up (bridged into br-lan)
c=$(hc -d 'iface=wlan&delay_ms=30' $U/cgi-bin/netem); t=$(r "tc qdisc show dev $AP root"); hc -d 'iface=wlan&action=clear' $U/cgi-bin/netem >/dev/null
log "wlan netem: $c $t"
echo "$t" | grep -q 'delay 30ms' && res W4-wlan PASS "iface=wlan -> $AP: $t" || res W4-wlan FAIL "$c $t"
c=$(hc -d 'profile=off' $U/cgi-bin/wifi); sleep 5
n=$(r "iw dev | grep -c 'type AP'"); st=$(r "wpa_cli -p /var/run/wpa_sta -i sta0 status | grep wpa_state")
hc $U/cgi-bin/wifi >/dev/null; g=$(body)
log "off: $c AP ifaces=$n STA $st GET $g"
[ "$c" = 200 ] && [ "$n" = 0 ] && ! echo "$st" | grep -q COMPLETED && res W3-off PASS "no AP interface, STA $st, GET $g" || res W3-off FAIL "$c n=$n $st"
wcase wpa2 "" "key_mgmt=WPA-PSK\n $P"
# ---------- W13 clients (STA connected by the wcase above) ----------
log "== W13 clients"
stamac=$(r "cat /sys/class/net/sta0/address")
c=$(hc $U/cgi-bin/clients); b=$(body); v=$(jchk "[x for x in j.get('$AP', []) if x['mac'] == '$stamac' and isinstance(x['signal_dbm'], int) and x['connected_s'] is not None]")
m=$(hc -d x=1 $U/cgi-bin/clients)
log "STA $stamac; clients: $c $b; POST $m"
[ "$c" = 200 ] && [ "$v" != "[]" ] && echo "$v" | grep -q "$stamac" && [ "$m" = 405 ] \
  && res W13-clients PASS "hwsim STA listed under $AP: $v; POST 405" || res W13-clients FAIL "$c $b post=$m"
r "kill \$(cat /tmp/sta.pid); iw dev sta0 del" >/dev/null   # test STA (not on the router) stopped from here on

# ---------- W9 injection ----------
log "== W9 injection"
r "rm -f /tmp/pwned" >/dev/null
UP0=$(r "cut -d. -f1 /proc/uptime"); S0=$(r "uci show wireless.bench; uci show dhcp.lan; tc qdisc show dev eth0 root; cat /etc/benchweb/profile" | md5sum)
fails=""
inj() {  # expected-code description curl-args...
  local e=$1 d=$2; shift 2
  local c=$(hc "$@"); log "$c  $d  -> $(body)"
  [ "$c" = "$e" ] || fails="$fails [$d: $c]"
}
inj 400 "profile=wpa2;reboot"        -d 'profile=wpa2;reboot' $U/cgi-bin/wifi
inj 400 "profile=wpa2;touch"         --data-urlencode 'profile=wpa2;touch /tmp/pwned' $U/cgi-bin/wifi
inj 400 'delay_ms=1$(reboot)'        -d 'iface=lan&delay_ms=1$(reboot)' $U/cgi-bin/netem
inj 400 'delay_ms=1$(touch) raw'     -d 'iface=lan&delay_ms=1$(touch /tmp/pwned)' $U/cgi-bin/netem
inj 400 'iface=lan;id'               -d 'iface=lan;id&delay_ms=1' $U/cgi-bin/netem
inj 400 'port=1 && id'               -d 'port=1 && id&action=down' $U/cgi-bin/port
inj 400 'port=1 && id (urlencoded)'  --data-urlencode 'port=1 && id' -d action=down $U/cgi-bin/port
inj 400 'port=1`touch`'              -d 'port=1`touch /tmp/pwned`&action=up' $U/cgi-bin/port
inj 400 'profile=wep'                -d 'profile=wep' $U/cgi-bin/wifi
inj 400 'channel=14'                 -d 'profile=wpa2&channel=14' $U/cgi-bin/wifi
inj 400 'channel=0x1'                -d 'profile=wpa2&channel=0x1' $U/cgi-bin/wifi
inj 400 'delay_ms=5001'              -d 'iface=lan&delay_ms=5001' $U/cgi-bin/netem
inj 400 'loss_pct=101'               -d 'iface=lan&loss_pct=101' $U/cgi-bin/netem
inj 400 'delay_ms=-1'                -d 'iface=lan&delay_ms=-1' $U/cgi-bin/netem
inj 400 'delay_ms=99999999999'       -d 'iface=lan&delay_ms=99999999999' $U/cgi-bin/netem
inj 400 'iface=eth0'                 -d 'iface=eth0&delay_ms=1' $U/cgi-bin/netem
inj 400 'dhcp action=maybe'          -d 'action=maybe' $U/cgi-bin/dhcp
inj 400 'newline in body'            --data-binary $'action=on\nreboot' $U/cgi-bin/dhcp
inj 400 'upgrade?confirm=1;reboot'   -X POST "$U/cgi-bin/upgrade?confirm=1;reboot"
inj 400 'upgrade?keep=$(id)'         -X POST "$U/cgi-bin/upgrade?confirm=1&keep=\$(id)"
head -c 600 /dev/zero | tr '\0' a | sed 's/^/action=on\&x=/' > $RUN/big.txt
inj 400 'form body 600 bytes'        --data-binary @$RUN/big.txt $U/cgi-bin/dhcp
head -c 300000 /dev/urandom > $RUN/r300k
inj 400 'restore body 300 KB'        -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$RUN/r300k $U/cgi-bin/restore
inj 400 'path ../../etc/passwd'      --path-as-is $U/cgi-bin/../../etc/passwd
inj 400 'path /../etc/benchweb'      --path-as-is $U/../etc/benchweb/password
inj 400 'path %2e%2e encoded'        --path-as-is $U/cgi-bin/%2e%2e/%2e%2e/etc/passwd
inj 404 'cgi-bin/nonexistent'        $U/cgi-bin/sh
inj 403 'cgi-bin/ listing'           $U/cgi-bin/
inj 405 'GET /cgi-bin/reboot'        $U/cgi-bin/reboot
inj 405 'POST /cgi-bin/status'       -d x=1 $U/cgi-bin/status
sleep 3
UP1=$(r "cut -d. -f1 /proc/uptime"); S1=$(r "uci show wireless.bench; uci show dhcp.lan; tc qdisc show dev eth0 root; cat /etc/benchweb/profile" | md5sum)
pw=$(r "ls /tmp/pwned 2>&1"); lg=$(r "logread | grep -c 'benchweb.*'")
log "uptime $UP0 -> $UP1; state hash $S0 -> $S1; /tmp/pwned: $pw; benchweb log lines: $lg"
[ -z "$fails" ] && [ "$UP1" -gt "$UP0" ] && [ "$S0" = "$S1" ] && echo "$pw" | grep -q 'No such file' \
  && res W9 PASS "29 attacks: all got the expected code (injections and bad values 400, traversal 400/404, listing 403, wrong method 405); no reboot, uci/tc unchanged, /tmp/pwned absent" \
  || res W9 FAIL "fails:$fails up $UP0->$UP1 state $S0/$S1 pwned=$pw"

# ---------- S: fixes from the security review ----------
log "== S2 netem auto-clear timer does not hold the lock; clear cancels it"
c1=$(hc -d 'iface=wan&delay_ms=10&for_s=120' $U/cgi-bin/netem)
T0=$(date +%s); c2=$(hc -d action=on $U/cgi-bin/dhcp); dt=$(( $(date +%s) - T0 ))
c3=$(hc -d 'iface=wan&action=clear' $U/cgi-bin/netem); sleep 1
g=$(r "ls /tmp/benchweb.netem.* 2>&1; ps w | grep -c '[s]leep 120'; tc qdisc show dev eth1 root | cut -c1-20")
log "set wan for_s=120: $c1; dhcp during timer: $c2 in ${dt}s; clear: $c3; guest: $(echo $g)"
[ "$c1$c2$c3" = 200200200 ] && [ $dt -le 5 ] && echo "$g" | grep -q 'No such file' && echo "$g" | grep -qx 0 && ! echo "$g" | grep -q '^qdisc netem' \
  && res S2-netem-lock PASS "dhcp change during a 120 s wan timer: 200 in ${dt} s; clear: 200, timer and its sleep gone, netem removed" \
  || res S2-netem-lock FAIL "$c1 $c2 ${dt}s $c3 $(echo $g)"

log "== S3 timers are per interface"
c1=$(hc -d 'iface=lan&delay_ms=20&for_s=8' $U/cgi-bin/netem)
c2=$(hc -d 'iface=wan&delay_ms=10' $U/cgi-bin/netem)
g1=$(r "ls /tmp/benchweb.netem.*; logread | grep 'benchweb.*netem iface=lan action=set delay_ms=20' | wc -l"); sleep 12
for i in 1 2 3; do g2=$(r "tc qdisc show dev eth0 root; tc qdisc show dev eth1 root"); echo "$g2" | grep -q '^qdisc ' && break; sleep 2; done
hc -d 'iface=wan&action=clear' $U/cgi-bin/netem >/dev/null
log "lan for_s=8 then wan set: $c1 $c2; guest: $(echo $g1); 12 s later: $(echo "$g2" | cut -c1-30 | tr '\n' ' ')"
echo "$g1" | grep -q '^/tmp/benchweb.netem.lan$' && [ "$(echo "$g1" | tail -n 1)" -ge 1 ] \
  && echo "$g2" | head -n 1 | grep -q '^qdisc ' && ! echo "$g2" | head -n 1 | grep -q netem && echo "$g2" | tail -n 1 | grep -q 'netem.*delay 10ms' \
  && res S3-netem-iface PASS "pidfile /tmp/benchweb.netem.lan and audit 'iface=lan'; a later wan change kept the lan timer: lan cleared after 8 s, wan netem untouched" \
  || res S3-netem-iface FAIL "$c1 $c2 $(echo $g1) / $(echo $g2)"

log "== S4 cross-origin and Host checks"
d0=$(r "uci -q get dhcp.lan.ignore")
o1=$(hc -H 'Origin: http://evil.example' -d action=off $U/cgi-bin/dhcp)
o2=$(hc -H 'Origin: null' -d action=off $U/cgi-bin/dhcp)
o3=$(hc -H 'Host: evil.example' $U/cgi-bin/status)
o4=$(hc -H 'Origin: http://evil.example' -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$RUN/bk0.tgz $U/cgi-bin/restore)
o5=$(hc -H 'Expect:' --data-binary @$RUN/bk0.tgz $U/cgi-bin/restore); b5=$(body)
o6=$(hc -H 'Expect:' -H 'Content-Type: text/plain' --data-binary @$RUN/bk0.tgz $U/cgi-bin/upgrade)
o7=$(hc -H "Origin: http://$IP" -H "Host: $IP:80" -d action=on $U/cgi-bin/dhcp)
xf=$(curl -s -D - -o /dev/null -u "bench:$PW" $U/cgi-bin/dhcp | tr -d '\r' | grep -i '^X-Frame-Options')
d1=$(r "uci -q get dhcp.lan.ignore; ls /etc/uci-defaults")
log "Origin evil $o1, Origin null $o2, Host evil $o3, restore cross-origin $o4, restore without Content-Type $o5 $b5, upgrade text/plain $o6, same origin $o7, header '$xf', dhcp.lan.ignore '$d0' -> '$(echo $d1)'"
[ "$o1$o2$o3$o4" = 403403403403 ] && [ "$o5$o6" = 400400 ] && [ "$o7" = 200 ] && [ "$xf" = 'X-Frame-Options: SAMEORIGIN' ] && [ -z "$d0" ] && ! echo "$d1" | grep -q '^1$' \
  && res S4-csrf PASS "Origin evil.example/null 403, Host evil.example 403, cross-origin restore 403; restore/upgrade without octet-stream 400; same origin 200; X-Frame-Options SAMEORIGIN; state unchanged" \
  || res S4-csrf FAIL "$o1 $o2 $o3 $o4 $o5 $o6 $o7 '$xf' '$d0' $(echo $d1)"

log "== S5 stalled upload releases the lock (upload_timeout_s=10)"
r "echo upload_timeout_s=10 >> /etc/benchweb/web.conf" >/dev/null
python3 $RUN/slow.py "$PW" /cgi-bin/restore 60 > $RUN/slow.out & SP=$!; sleep 2
T0=$(date +%s); c=$(hc -d action=on $U/cgi-bin/dhcp); dt=$(( $(date +%s) - T0 ))
wait $SP; so=$(cat $RUN/slow.out)
g=$(r "sed -i '/^upload_timeout_s=10$/d' /etc/benchweb/web.conf; ps w | grep -c '[h]ead -c 200000'; ls /tmp/restore.tgz 2>&1")
log "dhcp during stalled restore: $c after ${dt} s; stalled client: $so; guest: $(echo $g)"
[ "$c" = 200 ] && [ $dt -le 20 ] && echo "$so" | grep -q 'short body' && echo "$g" | grep -qx 0 && echo "$g" | grep -q 'No such file' \
  && res S5-stall PASS "stalled 200,000-byte restore (2 bytes sent): dhcp got the lock after ${dt} s; stalled client got 400 short body; no head left, temp file removed" \
  || res S5-stall FAIL "$c ${dt}s '$so' $(echo $g)"

log "== S6 client outside the LAN subnet (WAN side)"
# Test-only: the runner gets 10.9.9.2 on the LAN bridge and the guest a route to 10.9.9.0/24 on br-lan,
# so a request from a non-LAN source address reaches the CGIs (as from the WAN side with no firewall).
ip addr add 10.9.9.2/24 dev br0; r "ip route add 10.9.9.0/24 dev br-lan" >/dev/null
w1=$(hcode --interface 10.9.9.2 -u "bench:$PW" $U/cgi-bin/status); wb=$(body)
w2=$(hcode --interface 10.9.9.2 -u "bench:$PW" -d action=off $U/cgi-bin/dhcp)
w3=$(hcode --interface 10.9.9.2 -u "bench:$PW" $U/)
r "ip route del 10.9.9.0/24 dev br-lan" >/dev/null; ip addr del 10.9.9.2/24 dev br0
d1=$(r "uci -q get dhcp.lan.ignore")
log "from 10.9.9.2: status $w1 $wb, dhcp off $w2, / $w3; dhcp.lan.ignore '$d1'"
[ "$w1$w2" = 403403 ] && [ -z "$d1" ] \
  && res S6-wan PASS "from 10.9.9.2: CGIs 403 $wb, dhcp unchanged; static page still served ($w3)" \
  || res S6-wan FAIL "$w1 $w2 $w3 '$d1'"

log "== S7 restore rejects links, devices and .."
rs=""
for k in symlink hardlink dotdot fifo; do
  python3 $RUN/mk.py $RUN/$k.tgz $k
  c=$(hc -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$RUN/$k.tgz $U/cgi-bin/restore); rs="$rs $k=$c"
done
g=$(r "ls -d /etc/zz /etc/hl /etc/ff /etc/uci-defaults/99-sec /tmp/restore.tgz 2>/dev/null | wc -l; ls -ld / | cut -c1-10")
log "restores:$rs; files written, mode of /: $(echo $g)"
[ "$rs" = " symlink=400 hardlink=400 dotdot=400 fifo=400" ] && [ "$(echo $g)" = "0 drwxr-xr-x" ] \
  && res S7-restore-types PASS "symlink escape, hardlink, etc/.. and fifo archives -> 400; nothing written (no etc/uci-defaults/99-sec), / still 755" \
  || res S7-restore-types FAIL "$rs $(echo $g)"

# ---------- W10b memory during upload ----------
log "== W10 memory during a 3.9 MB upload"
VB=$IMG/variant-b-rootfs-ext4.img.gz
# lower the guard so the upload is stored (at 32M MemAvailable sits near the 6,144 kB default; W8-guard tests it)
r "echo min_mem_kb=4096 >> /etc/benchweb/web.conf" >/dev/null
curl -s -m 300 -u "bench:$PW" -H 'Expect:' -H 'Content-Type: application/octet-stream' --limit-rate 150k \
  --data-binary @$VB -o $RUN/up.json $U/cgi-bin/upgrade &
CP=$!
sleep 12; m1=$(memsnap); log "after 12 s: $m1"
wait $CP; log "upload result: $(cat $RUN/up.json)"
m2=$(memsnap); log "upload stored in /tmp/fw.bin: $m2"
r "rm -f /tmp/fw.bin; sed -i '/^min_mem_kb=4096$/d' /etc/benchweb/web.conf" >/dev/null; sleep 2; m3=$(memsnap); log "after rm: $m3"
MA1=$(echo "$m1" | sed -n 's/.*MemAvailable: \([0-9]*\).*/\1/p'); MA2=$(echo "$m2" | sed -n 's/.*MemAvailable: \([0-9]*\).*/\1/p'); MA3=$(echo "$m3" | sed -n 's/.*MemAvailable: \([0-9]*\).*/\1/p')
grep -q '"test": *"passed"' $RUN/up.json && echo "$m2" | grep -q 'tmpfs' \
  && res W10 INFO "upload accepted ($(grep -o '"size":[0-9]*' $RUN/up.json)); MemAvailable idle $MA0 kB; 12 s into upload $MA1 kB; image held in /tmp $MA2 kB ($(echo "$m2" | sed -n 's/.*tmpfs *[0-9]* *\([0-9]*\).*/\1/p') kB tmpfs used); after rm $MA3 kB; httpd idle: $(echo "$m0" | grep 'httpd pid' | sed 's/.*VmRSS: //' | head -1)" \
  || res W10 FAIL "upload not accepted: $(cat $RUN/up.json)"

# ---------- S1 connection flood (last before W7: W7's restore reboots the guest) ----------
log "== S1 unauthenticated connection flood"
adj=$(r 'for p in $(pidof httpd); do cat /proc/$p/oom_score_adj; done | sort -u')
r "dmesg -c >/dev/null"; p0=$(pids)
python3 $RUN/flood.py 300 30 > $RUN/flood.out & FP=$!
sleep 20; fm=$(r "grep MemAvailable /proc/meminfo" | tr -s ' '); wait $FP
for i in $(seq 1 30); do c=$(hc $U/cgi-bin/status); [ "$c" = 200 ] && break; sleep 2; done
p1=$(pids)
k=$(r "dmesg | sed -n 's/.*Killed process [0-9]* (\([^)]*\)).*oom_score_adj:\(-*[0-9]*\).*/\1:\2/p' | sort | uniq -c" | tr -s ' ' | tr '\n' ';')
log "httpd oom_score_adj: $adj; flood: $(cat $RUN/flood.out | tr '\n' ' '); during: $fm; status after: $c (try $i)"; log "pids before: $(echo $p0)"; log "pids after:  $(echo $p1)"; log "OOM kills: $k"
# Every OOM victim must have oom_score_adj 1000: httpd or a CGI shell it forked (they inherit 1000; background jobs reset
# to 0). An earlier rule, "named httpd", failed when a CGI sh was running at OOM time.
[ "$adj" = 1000 ] && [ "$c" = 200 ] && [ "$p0" = "$p1" ] && ! echo "$k" | grep -v '^ *$' | tr ';' '\n' | grep -v '^ *$' | grep -qv ':1000$' \
  && res S1-oom PASS "httpd oom_score_adj 1000; 300-connection flood ($(head -c 60 $RUN/flood.out | tr '\n' ' ')): OOM kills only processes with oom_score_adj 1000, httpd and its CGI children ($k); procd ubusd logd netifd dnsmasq dropbear hostapd wpa_supplicant same PIDs; status 200 after ${i} tries" \
  || res S1-oom FAIL "adj=$adj status=$c kills=$k pids $(echo $p0) / $(echo $p1)"

# ---------- W7 backup / restore ----------
log "== W7 backup/restore"
r "uci set system.@system[0].notes=w7-before; uci commit system" >/dev/null
rm -f $RUN/bk.tgz
c=$(curl -s -m 120 -u "bench:$PW" -o $RUN/bk.tgz -D $RUN/bk.hdr -w '%{http_code}' $U/cgi-bin/backup)
tr -d '\r' < $RUN/bk.hdr | tee -a $OUT
tar -tzf $RUN/bk.tgz > $RUN/bk.list 2>&1; tv=$?
cat $RUN/bk.list | tee -a $OUT
nc=$(grep -c '^etc/config/' $RUN/bk.list); hasbw=$(grep -c '^etc/benchweb/' $RUN/bk.list)
nt=$(tar -xzOf $RUN/bk.tgz etc/config/system 2>/dev/null | grep -c w7-before)
[ "$c" = 200 ] && [ $tv = 0 ] && [ $nc -ge 5 ] && [ $hasbw -ge 3 ] && [ $nt = 1 ] && grep -q 'application/gzip' $RUN/bk.hdr \
  && res W7-backup PASS "$(stat -c %s $RUN/bk.tgz) bytes application/gzip, tar -tzf ok, $nc files in etc/config ($(grep '^etc/config/' $RUN/bk.list | sed 's#etc/config/##' | tr '\n' ' ')), $hasbw in etc/benchweb" \
  || res W7-backup FAIL "code=$c tar=$tv config=$nc benchweb=$hasbw notes=$nt"
# negative restores
head -c 2000 /dev/urandom > $RUN/garbage
c1=$(hc -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$RUN/garbage $U/cgi-bin/restore); b1=$(body)
mkdir -p $RUN/evil/tmp && echo x > $RUN/evil/tmp/evil && tar -czf $RUN/evil.tgz -C $RUN/evil tmp/evil
c2=$(hc -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$RUN/evil.tgz $U/cgi-bin/restore); b2=$(body)
log "garbage: $c1 $b1 / tmp/evil archive: $c2 $b2"
[ "$c1$c2" = 400400 ] && res W7-reject PASS "random bytes -> 400 $b1; archive with tmp/evil -> 400 $b2" || res W7-reject FAIL "$c1 $b1 $c2 $b2"
r "uci set system.@system[0].notes=w7-after; uci commit system" >/dev/null
UPR=$(r "cut -d. -f1 /proc/uptime")
c=$(hc -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$RUN/bk.tgz $U/cgi-bin/restore); b=$(body); log "restore: $c $b"
waitdown 60; d=$?
waitssh 60; u=$?
sleep 15
n=$(r "uci -q get system.@system[0].notes"); up=$(r "cut -d. -f1 /proc/uptime")
c2=$(hc $U/cgi-bin/status); s=$(jchk "j['uptime']")
log "after restore reboot: notes=$n uptime=$up (was $UPR) status $c2 uptime=$s"
[ "$c" = 200 ] && [ $d = 0 ] && [ $u = 0 ] && [ "$n" = w7-before ] && [ "$up" -lt "$UPR" ] && [ "$c2" = 200 ] \
  && res W7-restore PASS "notes w7-after -> restore -> rebooted (uptime ${up}s) -> notes=$n; web UI up with same password" \
  || res W7-restore FAIL "code=$c down=$d up=$u notes=$n uptime=$up status=$c2"

# ---------- W8 upgrade ----------
log "== W8 upgrade"
# The stock malta kernel leaves about 6.5 MB less RAM than the trimmed router kernel (MemTotal 21,528 kB here),
# so at -m 32M MemAvailable sits just under the 6,144 kB default. The guard firing is checked below (W8-guard);
# for the rest of W8 the threshold is lowered to 4,096 kB in web.conf.
m=$(memsnap); log "before W8: $m"
c=$(hc -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$VB $U/cgi-bin/upgrade); b=$(body); f=$(r "ls /tmp/fw.bin 2>&1")
log "default guard: $c $b ($f)"
if [ "$c" = 507 ]; then res W8-guard PASS "default 6144 kB guard at 32M QEMU: 507 $b, nothing stored"
else res W8-guard INFO "MemAvailable above 6144 kB this time: $c"; r "rm -f /tmp/fw.bin" >/dev/null; fi
r "echo min_mem_kb=4096 >> /etc/benchweb/web.conf" >/dev/null
c=$(hc -X POST "$U/cgi-bin/upgrade?confirm=1&sha256=$(sha256sum $VB | cut -d' ' -f1)"); b=$(body); log "confirm without upload: $c $b"
[ "$c" = 409 ] && res W8-noimage PASS "confirm before upload -> 409 $b" || res W8-noimage FAIL "$c $b"
c=$(hc -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$RUN/garbage $U/cgi-bin/upgrade); b=$(body); f=$(r "ls /tmp/fw.bin 2>&1")
log "garbage: $c $b ($f)"
[ "$c" = 400 ] && echo "$f" | grep -q 'No such' && res W8-garbage PASS "2000 random bytes -> 400 $b; /tmp/fw.bin removed" || res W8-garbage FAIL "$c $b $f"
head -c 5000000 /dev/urandom > $RUN/r5m
T0=$(date +%s); c=$(hc -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$RUN/r5m $U/cgi-bin/upgrade); b=$(body); f=$(r "ls /tmp/fw.bin 2>&1")
log "5 MB: $c $b ($(( $(date +%s) - T0 )) s, $f)"
[ "$c" = 400 ] && echo "$f" | grep -q 'No such' && res W8-toolarge PASS "5,000,000 bytes -> 400 $b, nothing stored" || res W8-toolarge FAIL "$c $b $f"
r "sed -i 's/^min_mem_kb=4096/min_mem_kb=999999/' /etc/benchweb/web.conf" >/dev/null
c=$(hc -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$VB $U/cgi-bin/upgrade); b=$(body); f=$(r "ls /tmp/fw.bin 2>&1")
r "sed -i 's/^min_mem_kb=999999/min_mem_kb=4096/' /etc/benchweb/web.conf" >/dev/null
log "low memory (min_mem_kb=999999): $c $b ($f)"
[ "$c" = 507 ] && echo "$f" | grep -q 'No such' && res W8-lowmem PASS "simulated (min_mem_kb=999999 in web.conf) -> 507 $b, nothing stored" || res W8-lowmem FAIL "$c $b $f"
# S9: a tested image is deleted after image_keep_s (10 s here)
r "echo image_keep_s=10 >> /etc/benchweb/web.conf" >/dev/null
c=$(hc -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$VB $U/cgi-bin/upgrade); b=$(body); f0=$(r "ls /tmp/fw.bin 2>&1"); sleep 16
f1=$(r "ls /tmp/fw.bin /tmp/benchweb.fw 2>&1; ps w | grep -c '[s]leep 10'"); c2=$(hc -X POST "$U/cgi-bin/upgrade?confirm=1&sha256=$(sha256sum $VB | cut -d' ' -f1)"); b2=$(body)
r "sed -i '/^image_keep_s=10$/d' /etc/benchweb/web.conf" >/dev/null
log "image_keep_s=10: upload $c $(echo $b | cut -c1-60), stored: $f0; 16 s later: $(echo $f1); confirm: $c2 $b2"
[ "$c" = 200 ] && [ "$f0" = /tmp/fw.bin ] && [ "$(echo "$f1" | grep -c 'No such file')" = 2 ] && echo "$f1" | tail -n 1 | grep -qx 0 && [ "$c2" = 409 ] \
  && res S9-image-expiry PASS "tested image kept in /tmp, deleted after image_keep_s=10; confirm afterwards -> 409 $b2" \
  || res S9-image-expiry FAIL "$c $f0 / $(echo $f1) / $c2 $b2"
m=$(memsnap); log "before real upload: $m"
c=$(hc -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @$VB $U/cgi-bin/upgrade); b=$(body)
log "variant B upload: $c $b"
lsum=$(sha256sum $VB | cut -d' ' -f1)
v=$(jchk "j.get('test')=='passed' and j['sha256']=='$lsum'")
[ "$c" = 200 ] && [ "$v" = True ] && res W8-test PASS "$(stat -c %s $VB) byte malta image -> sysupgrade -T passed, sha256 matches" || res W8-test FAIL "$c $b"
r "uci set system.@system[0].notes=w8-keep; uci commit system" >/dev/null
v0=$(r "cat /etc/fw-variant 2>&1")
UPR=$(r "cut -d. -f1 /proc/uptime")
# S8: confirm must name the sha256 of the stored image
s1=$(hc -X POST "$U/cgi-bin/upgrade?confirm=1"); sb1=$(body)
s2=$(hc -X POST "$U/cgi-bin/upgrade?confirm=1&sha256=$(echo $lsum | tr 0-9a-f 1-9a-f0)"); sb2=$(body)
log "confirm without sha256: $s1 $sb1; wrong sha256: $s2 $sb2"
[ "$s1$s2" = 400409 ] && r "ls /tmp/fw.bin" >/dev/null && res S8-sha256 PASS "confirm without sha256 -> 400 $sb1; wrong sha256 -> 409 $sb2; image kept for the real confirm" || res S8-sha256 FAIL "$s1 $sb1 $s2 $sb2"
c=$(hc -d "sha256=$lsum" "$U/cgi-bin/upgrade?confirm=1"); b=$(body); log "confirm: $c $b"
waitdown 90; d=$?
waitssh 90; u=$?
sleep 20
v1=$(r "cat /etc/fw-variant"); n=$(r "uci -q get system.@system[0].notes"); up=$(r "cut -d. -f1 /proc/uptime")
c2=$(hc $U/cgi-bin/status); s=$(jchk "j['firmware']")
rl "logread | grep -iE 'sysupgrade|upgrade|config restore' | head; ls -l /etc/benchweb /sysupgrade.tgz 2>&1"
log "after upgrade: fw-variant '$v0' -> '$v1', notes=$n, uptime $up, status $c2 ($s)"
[ "$c" = 200 ] && [ $d = 0 ] && [ $u = 0 ] && [ "$v1" = B ] && [ "$n" = w8-keep ] && [ "$c2" = 200 ] \
  && res W8-upgrade PASS "confirm (sha256 in the form body, as the page sends it) -> 200 $b; guest rebooted into variant B (/etc/fw-variant=B, was absent), settings kept (notes=w8-keep), same web password, ssh key works" \
  || res W8-upgrade FAIL "code=$c down=$d up=$u variant=$v1 notes=$n status=$c2"

cp $RUN/console.log $W/logs/web-console-${MEM}M.log
pkill -f qemu-system-mips; sleep 2

# ---------- W15 factory reset ----------
# The ext4 image above has no overlay, so firstboot has nothing to erase. This boot uses overlay-disk.img.gz
# (build-web.sh): the same rootfs as squashfs plus an ext4 rootfs_data, mounted as the overlay as on the router.
log "== W15 factory reset (squashfs root, ext4 overlay)"
zcat $IMG/overlay-disk.img.gz > $RUN/ov.img
qemu-system-mips -M malta -cpu 24Kc -m ${MEM}M -nographic -vga none -monitor none \
  -serial file:$RUN/console-reset.log \
  -kernel $IMG/vmlinux.elf -append "root=/dev/sda rootfstype=squashfs rootwait console=ttyS0" \
  -drive file=$RUN/ov.img,format=raw,if=ide \
  -nic tap,ifname=tap0,script=no,downscript=no,model=pcnet,mac=52:54:00:50:00:01 \
  -nic user,model=pcnet,mac=52:54:00:50:00:02,net=10.0.2.0/24 \
  </dev/null >$RUN/qemu-reset.out 2>&1 &
if waitssh 120; then
  sleep 20
  PW=$(r "cat /etc/benchweb/password"); h0=$(r "md5sum < /etc/benchweb/password")
  mt=$(r "mount | grep -E ' on / type overlay| on /overlay type'")
  ST='uci -q get system.@system[0].hostname; uci -q get wireless.bench.ssid; uci -q get wireless.bench.encryption; uci -q get wireless.radio0.disabled; uci -q get wireless.radio0.channel; uci -q get wireless.radio0.country; uci -q get network.lan.ipaddr; uci -q get dropbear.@dropbear[0].PasswordAuth; ls /etc/uci-defaults | wc -l; ls -ld /etc/dropbear | cut -c1-10; ls -l /etc/dropbear/authorized_keys | cut -c1-10'
  s0=$(r "$ST" | tr '\n' ' ')
  r "touch /etc/w15-marker; uci set system.@system[0].hostname=w15-changed; uci set wireless.bench.ssid=w15-changed; uci set wireless.radio0.channel=6; uci commit; sync" >/dev/null
  s1=$(r "ls /overlay/upper/etc/w15-marker; $ST" | tr '\n' ' ')
  log "mounts: $(echo $mt)"; log "first boot: $s0"; log "changed: $s1"
  n0=$(hc $U/cgi-bin/reset); n1=$(hc -X POST $U/cgi-bin/reset); n2=$(hc -d confirm=no $U/cgi-bin/reset); n3=$(hc -d 'confirm=yes;reboot' $U/cgi-bin/reset)
  n4=$(hc -H 'Origin: http://evil.example' -d confirm=yes $U/cgi-bin/reset); sleep 3
  k=$(r "ls /etc/w15-marker")
  log "GET $n0, no confirm $n1, confirm=no $n2, 'confirm=yes;reboot' $n3, cross-origin $n4; marker after these: $k"
  BID=$(r "cat /proc/sys/kernel/random/boot_id")
  c=$(hc -d confirm=yes $U/cgi-bin/reset); b=$(body); log "reset: $c $b"
  waitdown 60; d=$?
  waitssh 90; u=$?
  sleep 20
  s2=$(r "ls /etc/w15-marker /overlay/upper/etc/w15-marker 2>&1 | grep -c 'No such file'; $ST" | tr '\n' ' ')
  up=$(r "cut -d. -f1 /proc/uptime"); bid=$(r "cat /proc/sys/kernel/random/boot_id"); h1=$(r "md5sum < /etc/benchweb/password")
  o=$(hc $U/cgi-bin/status); PW=$(r "cat /etc/benchweb/password"); n=$(hc $U/cgi-bin/status)
  log "after reset: $s2; uptime $up, new boot_id: $([ -n "$bid" ] && [ "$bid" != "$BID" ] && echo yes || echo no); password changed: $([ "$h0" != "$h1" ] && echo yes || echo no); status with old password $o, new $n"
  [ "$(echo $mt | grep -c overlay)" = 1 ] && [ "$n0$n1$n2$n3$n4" = 405400400400403 ] && [ "$k" = /etc/w15-marker ] \
    && echo "$s1" | grep -q '^/overlay/upper/etc/w15-marker w15-changed w15-changed' \
    && [ "$c" = 200 ] && [ $d = 0 ] && [ $u = 0 ] && [ -n "$bid" ] && [ "$bid" != "$BID" ] && [ "$s2" = "2 $s0" ] && [ "$h0" != "$h1" ] && [ "$o$n" = 401200 ] \
    && res W15-reset PASS "overlay = ext4 rootfs_data (loop on the squashfs disk); GET 405, no/other confirm 400, cross-origin 403, marker kept; confirm=yes -> 200 $b, rebooted (uptime ${up}s), marker gone from /overlay/upper, first-boot state back: $s0(hostname ssid enc disabled channel country lan PasswordAuth uci-defaults-left /etc/dropbear authorized_keys); new web password (old 401, new 200)" \
    || res W15-reset FAIL "mt=$(echo $mt) neg=$n0$n1$n2$n3$n4 k=$k s1=$s1 c=$c d=$d u=$u up=$up boot_id=$BID/$bid s0=$s0 s2=$s2 pw:$o$n"

  # ---------- W17 overlayfs on the root (xattr) ----------
  # Same overlay as the router after first boot: squashfs lower, writable upper. Remove, recreate and rename
  # directories that exist only in the lower layer (/rom). Without xattr support these return EIO.
  log "== W17 root overlay: rmdir/mkdir/rename of lower-layer directories"
  o=$(r "set -e; ls -d /rom/mnt /rom/etc/rc.button >/dev/null
     rmdir /mnt; echo rmdir=ok; mkdir /mnt; echo mkdir=ok entries=\$(ls -A /mnt | wc -l)
     n=\$(ls /etc/rc.button | wc -l); mv /etc/rc.button /etc/rc.button.w17; echo rename=ok files=\$(ls /etc/rc.button.w17 | wc -l)/\$n old=\$([ -e /etc/rc.button ] && echo present || echo gone)
     rm -rf /etc/rc.button.w17/*; rmdir /etc/rc.button.w17; mkdir /etc/rc.button; echo recreate=ok entries=\$(ls -A /etc/rc.button | wc -l)
     cp -a /rom/etc/rc.button/. /etc/rc.button/; echo restored=\$(ls /etc/rc.button | wc -l); sync" 2>&1)
  dm=$(r "dmesg | grep -i overlayfs | head -3")
  log "$o"; log "dmesg: $dm"
  echo "$o" | grep -q '^rmdir=ok$' && echo "$o" | grep -q '^mkdir=ok entries=0$' && echo "$o" | grep -qE '^rename=ok files=([0-9]+)/\1 old=gone$' \
    && echo "$o" | grep -q '^recreate=ok entries=0$' && ! echo "$dm" | grep -qi xattr \
    && res W17-overlay PASS "squashfs lower + ext4 upper: rmdir/mkdir of /mnt (empty, opaque), mv of /etc/rc.button ($(echo "$o" | sed -n 's/^rename=ok files=\([^ ]*\).*/\1/p') files), rm -rf and mkdir of it; no overlayfs xattr warning" \
    || res W17-overlay FAIL "$(echo $o) / dmesg: $(echo $dm)"
else
  tail -40 $RUN/console-reset.log | tee -a $OUT; res W15-reset FAIL "overlay disk did not boot"
fi
cp $RUN/console-reset.log $W/logs/web-console-reset-${MEM}M.log
pkill -f qemu-system-mips
log "done"
