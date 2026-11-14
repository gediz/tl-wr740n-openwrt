#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""settime.py: set the router clock from this PC and start its NTP server (images built with LAN_NTP=1).

  settime.py [--router IP] [--iface IF] [--key FILE] [--query]

The router has no RTC and no upstream time on a LAN without internet. An image built with LAN_NTP=1 keeps
sysntpd off at boot, so it never serves a wrong clock after a reboot. This script logs the router's offset
(one SNTP query, so the output doubles as a drift record), then writes this PC's time over an already open
SSH session at a second boundary, runs `date -s` and starts sysntpd if ntpd is not running.

  --router  router LAN address (default 192.168.1.1, or env ROUTER)
  --iface   send the SNTP query and the SSH session out of this interface (SO_BINDTODEVICE, ssh -B)
  --key     SSH private key (otherwise ssh's defaults and agent)
  --query   only print the offset, change nothing
Env LEAD: seconds to write early (default 0.010; busybox took about 10 ms from read to settimeofday).

Run it from cron to keep the router close to the PC clock, for example every 10 minutes:
  */10 * * * * /path/to/settime.py --router 192.168.1.1 >> ~/.local/state/router-time.log 2>&1
The PC clock should itself be in sync. SSH logs in as root with key auth and needs the router's host key
in known_hosts already (BatchMode).
"""
import argparse, os, socket, struct, subprocess, sys, time

E = 2208988800  # seconds from 1900 (NTP) to 1970 (Unix)


def query(router, iface):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    if iface:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode())
    t1 = time.time()
    pkt = bytearray(48)
    pkt[0] = 0x23  # LI 0, version 4, mode 3 (client)
    pkt[40:48] = struct.pack("!II", int(t1) + E, int((t1 % 1) * 2**32))
    try:
        s.sendto(pkt, (router, 123))
        d = s.recv(512)
    except OSError:
        return "no-ntp-answer"
    t4 = time.time()
    if len(d) < 48:
        return "short-ntp-answer"
    ts = lambda b: struct.unpack("!I", b[:4])[0] - E + struct.unpack("!I", b[4:])[0] / 2**32
    off = ((ts(d[32:40]) - t1) + (ts(d[40:48]) - t4)) / 2
    return f"offset={off * 1e3:+.1f}ms LI={d[0] >> 6} stratum={d[1]}"


def main():
    ap = argparse.ArgumentParser(description="Set the router clock from this PC and start its NTP server.")
    ap.add_argument("--router", default=os.environ.get("ROUTER", "192.168.1.1"))
    ap.add_argument("--iface")
    ap.add_argument("--key")
    ap.add_argument("--query", action="store_true")
    a = ap.parse_args()
    lead = float(os.environ.get("LEAD", "0.010"))

    before = query(a.router, a.iface)
    if a.query:
        print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), before)
        return 0
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "LogLevel=ERROR"]
    if a.key:
        ssh += ["-i", a.key, "-o", "IdentitiesOnly=yes"]
    if a.iface:
        ssh += ["-B", a.iface]
    cmd = "read t; date -s @$t >/dev/null; pgrep -x ntpd >/dev/null || /etc/init.d/sysntpd start; echo ok"
    p = subprocess.Popen(ssh + ["root@" + a.router, cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    time.sleep(1.5)  # let the session open, so only the one line below is in flight
    t = int(time.time()) + 1
    while time.time() < t - lead:
        pass
    try:
        p.stdin.write(f"{t}\n")
        p.stdin.close()
    except BrokenPipeError:
        pass
    out = p.stdout.read().strip().replace("\n", " ")
    p.wait()
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)), "before:", before, "push:", out or f"rc={p.returncode}")
    return 0 if out.endswith("ok") else 1


sys.exit(main())
