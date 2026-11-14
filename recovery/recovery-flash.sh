#!/bin/bash
# SPDX-License-Identifier: MIT
# recovery-flash.sh: flash a TL-WR740N v5 through TP-Link's U-Boot TFTP recovery (no serial needed).
#
# What U-Boot 1.1.4 on this board does (read from a flash dump, see ../docs/recovery.md): with the reset
# button held at power-on it takes 192.168.0.86 and fetches wr740nv5_tp_recovery.bin from a TFTP server at
# 192.168.0.66. It writes flash 0x020000-0x3dffff only when the file has the board's product id at +0x40
# and is exactly 0x3c0000 bytes (or 0x3e0200, a stock image with boot block). Any other size: it resets
# without writing. Wrong id: it boots the old firmware without writing.
#
# This script checks the file the same way, then serves it with dnsmasq (TFTP only, no DNS, no DHCP) on a
# DEDICATED wired interface that is cabled to a router LAN port, and shows the transfer as it happens.
#
# Usage:
#   recovery-flash.sh --iface IFACE --file IMAGE [--sha256 HEX] [--check-ip IP] [--dry-run]
#   recovery-flash.sh --iface IFACE --cleanup          (remove what an aborted run left behind)
#   --iface     wired interface with a cable to a router LAN port. It must not carry your internet:
#               the script refuses an interface with a default route. Also env RECOVERY_IFACE.
#   --file      the image: an OpenWrt factory image for this board, or a firmware partition cut from
#               your own flash dump (make-recovery-image.sh). Never a sysupgrade image (wrong size).
#   --sha256    refuse the file unless it has this sha256
#   --check-ip  after the flash, ping this address (for example 192.168.1.1, or your image's LAN_IP)
#               from a temporary .250 address on the same /24 on IFACE
#   --dry-run   check the file and the PC, print what would be done, change nothing
# Environment: PRODUCT_ID (default 0740000500000001, the v5's id at flash 0x1fd00; check yours with
#   make-recovery-image.sh), WAIT_REQ (600 s), WAIT_WRITE (150 s), WAIT_BOOT (300 s).
# Runs privileged commands through sudo. Hands-on steps: ../docs/recovery.md.
set -u
SRV=192.168.0.66; RTR=192.168.0.86
NAME=wr740nv5_tp_recovery.bin
SIZE=3932160                       # 0x3c0000
ID=${PRODUCT_ID:-0740000500000001}
BLOCKS=$((SIZE / 512))             # 512-byte TFTP data blocks (plus one empty final block)
RUN_BASE=${TMPDIR:-/tmp}/wr740n-recovery
RUN="$RUN_BASE.XXXXXX"              # made private with mktemp -d in step 2
DNSMASQ_PID=; TCPDUMP_PID=
WAIT_REQ=${WAIT_REQ:-600}          # seconds to wait for the router to ask for the file
WAIT_WRITE=${WAIT_WRITE:-150}      # seconds after the transfer for erase + write + restart
WAIT_BOOT=${WAIT_BOOT:-300}        # seconds for --check-ip to answer after that

IF=${RECOVERY_IFACE:-}; FILE=; WANT_SHA=; CHECK_IP=; DRY=0; CLEANUP=0
while [ $# -gt 0 ]; do
  case $1 in
    --iface) IF=${2:?--iface needs an interface}; shift ;;
    --file) FILE=${2:?--file needs a path}; shift ;;
    --sha256) WANT_SHA=${2:?--sha256 needs a value}; shift ;;
    --check-ip) CHECK_IP=${2:?--check-ip needs an address}; shift ;;
    --dry-run) DRY=1 ;;
    --cleanup) CLEANUP=1 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown option $1 (see --help)"; exit 2 ;;
  esac
  shift
done
[ -n "$IF" ] || { echo "--iface is required (see --help)"; exit 2; }
case $IF in *[!A-Za-z0-9_.-]*) echo "bad interface name '$IF'"; exit 2 ;; esac
case $CHECK_IP in ''|*[!0-9.]*) [ -z "$CHECK_IP" ] || { echo "bad --check-ip"; exit 2; } ;; esac
CHK_ADDR=${CHECK_IP:+${CHECK_IP%.*}.250}

say() { echo "[$(date +%H:%M:%S)] $*"; }
die() { say "STOP: $*"; exit 1; }
S() { if [ $DRY = 1 ]; then echo "  [dry-run] would run: sudo $*"; else sudo "$@"; fi; }
has_addr() { ip -o -4 addr show dev "$IF" | grep -q " $1/"; }
carrier() { cat /sys/class/net/$IF/carrier 2>/dev/null || echo 0; }
ask() {
  echo; echo ">>> $*"
  [ $DRY = 1 ] && { echo "  [dry-run] would wait for Enter here"; return; }
  read -r -p ">>> Press Enter when done (Ctrl-C aborts). " _
}

NM_OFF=0; TFTP_UP=0; FW_RULE=0; CHK_UP=0
nm_take() {
  command -v nmcli >/dev/null || return 0
  nmcli -g GENERAL.STATE device show "$IF" 2>/dev/null | grep -q '^10 ' && return 0   # already unmanaged
  say "NetworkManager: making $IF unmanaged for this run"
  S nmcli device set "$IF" managed no; NM_OFF=1
}
nm_give_back() {
  [ $NM_OFF = 1 ] || return 0
  say "NetworkManager: handing $IF back"
  S nmcli device set "$IF" managed yes; NM_OFF=0
}
tftp_stop() {
  # Kill only what this run started: tcpdump by $!, dnsmasq by its pid file in the private run dir.
  [ -n "$TCPDUMP_PID" ] && { S kill "$TCPDUMP_PID" 2>/dev/null; TCPDUMP_PID=; }
  [ -n "$DNSMASQ_PID" ] && { S kill "$DNSMASQ_PID" 2>/dev/null; DNSMASQ_PID=; }
  if [ $CLEANUP = 1 ]; then   # leftovers of a run that was killed: match our exact command lines
    S pkill -f -- "--tftp-root=$RUN_BASE\\.[A-Za-z0-9]{6}/tftp" 2>/dev/null
    S pkill -f -- "tcpdump -l -n -U -i $IF host $RTR or arp" 2>/dev/null
  fi
  if [ $FW_RULE = 1 ] || [ $CLEANUP = 1 ]; then
    while sudo iptables -C INPUT -i "$IF" -s $RTR -d $SRV -p udp -j ACCEPT 2>/dev/null; do
      S iptables -D INPUT -i "$IF" -s $RTR -d $SRV -p udp -j ACCEPT; done
    FW_RULE=0
  fi
  has_addr $SRV && S ip addr del $SRV/24 dev "$IF"
  TFTP_UP=0
}
on_exit() {
  [ $DRY = 1 ] && return
  [ $TFTP_UP = 1 ] && { say "cleanup: stopping TFTP, removing $SRV from $IF"; tftp_stop; }
  [ $CHK_UP = 1 ] && has_addr "$CHK_ADDR" && S ip addr del "$CHK_ADDR/24" dev "$IF"
  nm_give_back
}
trap on_exit EXIT
trap 'exit 130' INT TERM

if [ $CLEANUP = 1 ]; then
  command -v iptables >/dev/null || FW_RULE=0
  tftp_stop
  command -v nmcli >/dev/null && nmcli -g GENERAL.STATE device show "$IF" 2>/dev/null | grep -q '^10 ' && NM_OFF=1
  nm_give_back
  say "$IF now: $(ip -o -4 addr show dev "$IF" | awk '{print $4}' | tr '\n' ' ')"
  exit 0
fi

# ---------------------------------------------------------------- preflight
[ $DRY = 1 ] && say "DRY RUN: nothing will be changed"
for t in dnsmasq tcpdump ip ss xxd sha256sum; do command -v $t >/dev/null || die "missing tool: $t"; done
ip link show "$IF" >/dev/null 2>&1 || die "no interface $IF"
[ -n "$(ip route show default dev "$IF")" ] && die "$IF holds a default route: it looks like your internet link, not a cable to the router"
other=$(ip -o -4 addr | awk -v i="$IF" '$2!=i && $4 ~ /^192\.168\.0\./ {print $2" "$4}')
[ -z "$other" ] || die "192.168.0.x is already used on another interface ($other). U-Boot's addresses would clash."
ss -Huln "sport = :69" | grep -qE "($SRV|0\.0\.0\.0|\*):69 " && die "UDP port 69 is already in use"
say "PC: $IF $(ip -o -4 addr show dev "$IF" | awk '{print $4}' | tr '\n' ' ')(carrier $(carrier))"

# ---------------------------------------------------------------- the file
[ -n "$FILE" ] || die "--file is required"
[ -r "$FILE" ] || die "cannot read $FILE"
FILE=$(readlink -f "$FILE")
fsize=$(stat -c %s "$FILE")
fid=$(xxd -s 0x40 -l 8 -p "$FILE")
vendor=$(dd if="$FILE" bs=1 skip=4 count=24 2>/dev/null | tr -dc '[:print:]')
fwver=$(dd if="$FILE" bs=1 skip=28 count=36 2>/dev/null | tr -dc '[:print:]')
sha=$(sha256sum "$FILE" | cut -d' ' -f1)
say "file:    $FILE"
say "size:    $fsize bytes (need $SIZE = 0x3c0000)"
say "id@0x40: $fid (need $ID)"
say "header:  vendor '$vendor', version '$fwver'"
say "sha256:  $sha"
[ "$fsize" = $SIZE ] || die "wrong size. U-Boot would reset without writing. (A sysupgrade image is the wrong file; use the factory image.)"
[ "$fid" = "$ID" ] || die "wrong product id. U-Boot would refuse it and boot the old firmware."
if [ -n "$WANT_SHA" ]; then
  [ "$sha" = "$WANT_SHA" ] || die "sha256 does not match --sha256"
  say "sha256 matches --sha256"
else
  say "note: no --sha256 given; compare the value above with your sha256sums before you go on"
fi

# ---------------------------------------------------------------- address and TFTP server
say "step 1: take $IF, add $SRV/24"
nm_take
ask "Cable from $IF in a router LAN port (yellow), nothing in the blue WAN port. Unplug the router's power and leave it off."
S ip link set "$IF" up
has_addr $SRV || S ip addr add $SRV/24 dev "$IF"
TFTP_UP=1
if command -v iptables >/dev/null; then
  S iptables -I INPUT 1 -i "$IF" -s $RTR -d $SRV -p udp -j ACCEPT; FW_RULE=1   # in case a host firewall drops TFTP
fi

say "step 2: TFTP on $SRV only (dnsmasq, no DNS, no DHCP), serving the file as $NAME"
if [ $DRY = 0 ]; then
  # Private run directory: only this user can create files in it (0711), so nothing can be planted
  # next to the image. The tftp/ folder and the image stay readable for dnsmasq's unprivileged user.
  RUN=$(mktemp -d "$RUN_BASE.XXXXXX") || die "mktemp failed"
  mkdir "$RUN/tftp" && chmod 711 "$RUN" && chmod 755 "$RUN/tftp" || die "cannot set up $RUN"
  cp "$FILE" "$RUN/tftp/$NAME"; chmod 644 "$RUN/tftp/$NAME"
  [ "$(sha256sum < "$RUN/tftp/$NAME" | cut -d' ' -f1)" = "$sha" ] || die "copy in $RUN/tftp does not match"
  : > "$RUN/dnsmasq.log"; : > "$RUN/tcpdump.txt"
  sudo setsid dnsmasq --keep-in-foreground --log-facility=- --conf-file=/dev/null \
    --port=0 --no-resolv --no-hosts --enable-tftp --tftp-root="$RUN/tftp" --listen-address=$SRV --bind-interfaces \
    --pid-file="$RUN/dnsmasq.pid" >>"$RUN/dnsmasq.log" 2>&1 &
  sudo tcpdump -l -n -U -i "$IF" "host $RTR or arp" >>"$RUN/tcpdump.txt" 2>"$RUN/tcpdump.err" &
  TCPDUMP_PID=$!
  for i in $(seq 1 10); do ss -Huln "sport = :69" | grep -q "$SRV:69 " && break; sleep 1; done
  ss -Huln "sport = :69" | grep -q "$SRV:69 " || { cat "$RUN/dnsmasq.log"; die "TFTP server did not start"; }
  # setsid may fork, so $! is not dnsmasq; its pid file is safe to read here because $RUN is private.
  DNSMASQ_PID=$(sudo cat "$RUN/dnsmasq.pid" 2>/dev/null); case $DNSMASQ_PID in ''|*[!0-9]*) DNSMASQ_PID= ;; esac
  say "TFTP listening on $SRV:69"
else
  echo "  [dry-run] would copy the file to $RUN/tftp/$NAME and start: sudo dnsmasq --port=0 --enable-tftp --listen-address=$SRV --bind-interfaces ..."
  echo "  [dry-run] would start: sudo tcpdump -i $IF 'host $RTR or arp' (progress counter)"
fi

# ---------------------------------------------------------------- watch the transfer
say "step 3: waiting up to $((WAIT_REQ / 60)) min for the router"
cat <<EOF
>>> NOW: press and HOLD the router's WPS/RESET button. Keep holding it, plug the power in,
>>> count 5 seconds, then let go. (Held much longer, OpenWrt may see the button and start failsafe.)
>>> No 'recovery mode' line within a minute: unplug the power, try another LAN port, repeat.
EOF
if [ $DRY = 1 ]; then
  echo "  [dry-run] would watch: ARP for $SRV, the TFTP request, data blocks (of $BLOCKS), dnsmasq 'sent ... to $RTR'"
  echo "  [dry-run] would wait $WAIT_WRITE s after the transfer for erase + write + restart"
  exit 0
fi
t0=$(date +%s); seen_arp=0; seen_rrq=0; last=-1; done_at=0; lc=$(carrier); errs=0; n=0
while :; do
  now=$(date +%s)
  has_addr $SRV || { say "$SRV vanished from $IF, adding it again"; S ip addr add $SRV/24 dev "$IF"; }
  c=$(carrier); [ "$c" != "$lc" ] && { say "link on $IF: $([ "$c" = 1 ] && echo up || echo down)"; lc=$c; }
  [ $seen_arp = 0 ] && grep -q "who-has $SRV tell $RTR" "$RUN/tcpdump.txt" && { seen_arp=1; say "router is in recovery mode ($RTR is looking for $SRV)"; }
  [ $seen_rrq = 0 ] && grep -q "RRQ" "$RUN/tcpdump.txt" && { seen_rrq=1; say "router asked for: $(grep -o 'RRQ "[^"]*"' "$RUN/tcpdump.txt" | head -1)"; }
  n=$(grep -cE "IP $SRV\.[0-9]+ > $RTR\.[0-9]+: .*length 516" "$RUN/tcpdump.txt")
  pct=$((n * 100 / BLOCKS)); [ $pct -gt 100 ] && pct=100
  [ "$n" -gt 0 ] && [ $((pct / 10)) -ne $last ] && { last=$((pct / 10)); say "transfer ${pct}% ($n of $BLOCKS blocks)"; }
  e=$(grep -cE "failed|error|not found|refused" "$RUN/dnsmasq.log")
  [ "$e" -gt "$errs" ] && { errs=$e; say "TFTP problem: $(grep -E 'failed|error|not found|refused' "$RUN/dnsmasq.log" | tail -1)"; }
  grep -q "sent .*$NAME to $RTR" "$RUN/dnsmasq.log" && { done_at=$now; break; }
  [ $((now - t0)) -ge "$WAIT_REQ" ] && break
  sleep 1
done
if [ $done_at = 0 ]; then
  say "NOTHING HAPPENED in $((WAIT_REQ / 60)) min (arp seen: $seen_arp, request seen: $seen_rrq, blocks: $n)."
  say "Nothing was written to the router. Logs: $RUN/dnsmasq.log $RUN/tcpdump.txt"
  exit 3
fi
say "TRANSFER DONE in $((done_at - t0)) s"
say "The router now checks the product id, erases and writes flash, then restarts by itself."
say ">>> Do NOT unplug the router. Waiting $WAIT_WRITE s."
[ -n "$CHECK_IP" ] && say ">>> If the cable is in the WAN port, move it to a LAN port now (only the cable, never the power). The check after the restart needs a LAN port."
while [ $(( $(date +%s) - done_at )) -lt "$WAIT_WRITE" ]; do
  c=$(carrier); [ "$c" != "$lc" ] && { say "link on $IF: $([ "$c" = 1 ] && echo up || echo down)"; lc=$c; }
  sleep 2
done
sent=$(grep -c "sent .*$NAME to $RTR" "$RUN/dnsmasq.log"); [ "$sent" -gt 1 ] && say "note: the file was sent $sent times"

say "step 4: stop TFTP, remove $SRV from $IF"
tftp_stop

# ---------------------------------------------------------------- optional check
if [ -n "$CHECK_IP" ]; then
  say "step 5: waiting up to $WAIT_BOOT s for $CHECK_IP (from $CHK_ADDR/24 on $IF)"
  has_addr "$CHK_ADDR" || { S ip addr add "$CHK_ADDR/24" dev "$IF"; CHK_UP=1; }
  t1=$(date +%s); ok=0
  while [ $(( $(date +%s) - t1 )) -lt "$WAIT_BOOT" ]; do
    ping -c1 -W2 -I "$IF" "$CHECK_IP" >/dev/null 2>&1 && { ok=1; break; }; sleep 3
  done
  if [ $ok = 1 ]; then
    say "RESULT: $CHECK_IP answers after $(( $(date +%s) - t1 )) s. A factory image means a first boot: new SSH host key."
  else
    say "RESULT: $CHECK_IP did not answer in $WAIT_BOOT s. A first boot can be slow; try ping again, then see ../docs/recovery.md."
    exit 4
  fi
else
  say "RESULT: transfer done and the write wait is over. Check the router on its LAN address."
fi
