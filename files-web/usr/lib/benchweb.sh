# benchweb CGI helpers. Sourced by /www-bench/cgi-bin/*.
# Request data is never eval'ed or passed unquoted; every value is whitelisted.
B=/etc/benchweb
hdr() { printf 'Status: %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nX-Frame-Options: SAMEORIGIN\r\n\r\n' "$1"; }
ok() { hdr '200 OK'; echo "$1"; exit 0; }
err() { hdr "$1"; printf '{"error":"%s"}\n' "$2"; exit 0; }
bad() { err '400 Bad Request' "$1"; }
js() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/[\\"]/\\&/g'; }
need() { [ "$REQUEST_METHOD" = "$1" ] || err '405 Method Not Allowed' "use $1"; }
cl() { case "${CONTENT_LENGTH:-0}" in *[!0-9]*) bad length;; esac; L=${CONTENT_LENGTH:-0}; }
drain() { [ "$L" -gt 0 ] && cat >/dev/null; }
# raw: uploads must be application/octet-stream (not a type a cross-site form or fetch can send without preflight)
raw() { [ "$CONTENT_TYPE" = application/octet-stream ] || { drain; bad 'Content-Type must be application/octet-stream'; }; }
# form: query string plus urlencoded POST body (max 512 bytes); only [A-Za-z0-9_.=&-]
form() {
	F=$QUERY_STRING
	if [ "$REQUEST_METHOD" = POST ]; then
		cl; [ "$L" -le 512 ] || { drain; bad 'body too large'; }
		F="$F&$(head -c "$L")"
	fi
	case "$F" in *[!A-Za-z0-9_.=\&-]*) bad 'bad characters';; esac
}
arg() { printf '%s' "$F" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }
# num VALUE MIN MAX
num() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ ${#1} -le 5 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
lock() { local n; exec 9>/tmp/benchweb.lock; for n in 1 2 3 4 5 6 7 8 9 10; do flock -n 9 && return; sleep 2; done; err '409 Conflict' busy; }
audit() { logger -t benchweb "${REMOTE_USER:-?}@${REMOTE_ADDR:-?} ${SCRIPT_NAME##*/} $*"; }
# conf FILE KEY DEFAULT: read key=value without sourcing the file
conf() { v=$(sed -n "s/^$2=//p" "$B/$1" 2>/dev/null | head -n 1); echo "${v:-$3}"; }
memavail() { awk '/^MemAvailable:/{print $2}' /proc/meminfo; }
# Background work. httpd runs with oom_score_adj 1000 (init script); these jobs go back to 0 so a request
# flood cannot OOM-kill a pending reboot or netem auto-clear. job closes the lock fd (9), later keeps it.
later() { ( echo 0 >/proc/self/oom_score_adj; sleep 2; "$@" ) </dev/null >/dev/null 2>&1 & }
job() { ( echo 0 >/proc/self/oom_score_adj; "$@" ) </dev/null >/dev/null 2>&1 9>&- & }
# after SECONDS CMD...: (run with job) wait, take the lock, run CMD. stop PID cancels it.
after() { sleep $1 || exit; shift; exec 9>/tmp/benchweb.lock; flock 9 || exit; "$@"; }
stop() { case "$1" in ''|*[!0-9]*) return;; esac; kill $(pgrep -P $1) $1; } 2>/dev/null
wd() { sleep $1 && kill $2; }
# rbody FILE: request body ($L bytes) to FILE; gives up after upload_timeout_s (web.conf, default 300)
rbody() {
	local h w
	exec 3<&0
	head -c "$L" <&3 >"$1" & h=$!
	job wd "$(conf web.conf upload_timeout_s 300)" $h; w=$!
	wait $h; stop $w
}

# Every request: from the LAN subnet, Host is the LAN address, Origin (if sent) is this page.
# Blocks WAN-side clients (no firewall here), cross-site POSTs (CSRF) and DNS rebinding.
guard() {
	local ip=$(uci -q get network.lan.ipaddr)
	awk -v a="$REMOTE_ADDR" -v b="$ip" -v m="$(uci -q get network.lan.netmask)" '
		function n(s, p) { if (split(s, p, ".") != 4) return -1; return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
		BEGIN { split(b, q, "/"); k = m != "" ? n(m) : 2^32 - 2^(32 - (q[2] != "" ? q[2] : 24))
			exit !(n(a) >= 0 && k >= 0 && and(n(a), k) == and(n(q[1]), k)) }' || err '403 Forbidden' 'client not in the LAN subnet'
	ip=${ip%%/*}
	case "$HTTP_HOST" in ''|"$ip"|"$ip:80") ;; *) err '403 Forbidden' 'bad Host';; esac
	case "$HTTP_ORIGIN" in ''|"http://$ip") ;; *) err '403 Forbidden' 'cross-origin request';; esac
}
guard

# devs IFACE: kernel devices behind lan|wan|wlan
devs() {
	local d
	case "$1" in
	lan|wlan)
		[ -d /sys/class/net/br-lan/brif ] || { [ $1 = lan ] && uci -q get network.lan.device; return; }
		for d in /sys/class/net/br-lan/brif/*; do
			d=${d##*/}; [ -e /sys/class/net/$d ] || continue
			if [ -e /sys/class/net/$d/phy80211 ]; then [ $1 = wlan ] && echo $d; else [ $1 = lan ] && echo $d; fi
		done;;
	wan) uci -q get network.wan.device;;
	esac
}
netem_json() {
	local i d o= q
	for i in lan wan wlan; do
		q=
		for d in $(devs $i); do
			q="$q${q:+,}{\"dev\":\"$d\",\"netem\":\"$(js "$(tc qdisc show dev $d root | sed -n 's/^qdisc netem .* limit [0-9]* *//p')")\"}"
		done
		o="$o${o:+,}\"$i\":[$q]"
	done
	echo "{$o}"
}
sw() { swconfig list 2>/dev/null | sed -n 's/^Found: \([^ ]*\).*/\1/p' | head -n 1; }
ports_json() {
	local s=$(sw) p o=
	[ -n "$s" ] || { echo null; return; }
	for p in 1 2 3 4; do
		o="$o${o:+,}\"$p\":\"$(js "$(swconfig dev "$s" port $p get link | sed 's/^port:[0-9]* //')")\""
	done
	echo "{$o}"
}
aps() {
	local d
	for d in /sys/class/net/*; do
		[ -e $d/phy80211 ] && iw dev ${d##*/} info 2>/dev/null | grep -q 'type AP' && echo ${d##*/}
	done
}
wifi_if() { aps | head -n 1; }
wifi_json() {
	local i=$(wifi_if) p=$(cat $B/profile 2>/dev/null) inf
	[ -n "$i" ] || { echo "{\"profile\":\"${p:-unknown}\",\"up\":false}"; return; }
	inf=$(iwinfo $i info)
	printf '{"profile":"%s","up":true,"ifname":"%s","ssid":"%s","channel":"%s","encryption":"%s","clients":%s}' \
		"${p:-unknown}" $i "$(js "$(echo "$inf" | sed -n 's/.*ESSID: "\(.*\)"$/\1/p')")" \
		"$(echo "$inf" | sed -n 's/.*Channel: \([0-9]*\).*/\1/p')" \
		"$(js "$(echo "$inf" | sed -n 's/.*Encryption: //p')")" \
		"$(iwinfo $i assoclist | grep -c '^[0-9A-F][0-9A-F]:')"
}
