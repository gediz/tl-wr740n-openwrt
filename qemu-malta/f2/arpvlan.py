#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# arpvlan.py IFACE VID TARGET_IP SENDER_IP [TIMEOUT_S]
# Sends one ARP request for TARGET_IP out IFACE (raw socket), 802.1Q tagged with VID (0 = untagged), and waits
# for the reply. Prints "reply from MAC vid N" or "reply from MAC untagged", or "no reply". Exit 0 on a reply.
# Used on the runner's tap0 to stand in for the router's switch, which hands LAN frames to eth0 tagged with VID 1.
# The kernel moves a received 802.1Q tag into packet metadata, so the tag is read from PACKET_AUXDATA.
import socket, struct, sys, time

ifc, vid, tip, sip = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
timeout = float(sys.argv[5]) if len(sys.argv) > 5 else 3.0
SOL_PACKET, PACKET_AUXDATA, TP_STATUS_VLAN_VALID, PACKET_OUTGOING = 263, 8, 0x10, 4
mac = bytes.fromhex("02000000f201")  # locally administered, not used by anything else in the runner

s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
s.bind((ifc, 0))
s.setsockopt(SOL_PACKET, PACKET_AUXDATA, 1)
tag = struct.pack(">HH", 0x8100, vid) if vid else b""
arp = struct.pack(">HHBBH", 1, 0x0800, 6, 4, 1) + mac + socket.inet_aton(sip) + b"\0" * 6 + socket.inet_aton(tip)
frame = b"\xff" * 6 + mac + tag + b"\x08\x06" + arp
s.send(frame + b"\0" * max(0, 60 - len(frame)))

end = time.time() + timeout
while time.time() < end:
    s.settimeout(max(0.01, end - time.time()))
    try:
        data, anc, _, addr = s.recvmsg(2048, socket.CMSG_SPACE(20))
    except socket.timeout:
        break
    if addr[2] == PACKET_OUTGOING:
        continue
    rvid = None
    for lvl, typ, cd in anc:
        if lvl == SOL_PACKET and typ == PACKET_AUXDATA and len(cd) >= 20:
            status, _, _, _, _, tci, _ = struct.unpack("=IIIHHHH", cd[:20])
            if status & TP_STATUS_VLAN_VALID:
                rvid = tci & 0xfff
    et = data[12:14]
    p = data[14:]
    if et == b"\x81\x00":  # tag still in the frame
        rvid = struct.unpack(">H", data[14:16])[0] & 0xfff
        et, p = data[16:18], data[18:]
    if et != b"\x08\x06" or len(p) < 28 or data[:6] != mac:
        continue
    op = struct.unpack(">H", p[6:8])[0]
    if op == 2 and p[14:18] == socket.inet_aton(tip):
        print("reply from %s %s" % (p[8:14].hex(":"), "vid %d" % rvid if rvid is not None else "untagged"))
        sys.exit(0)
print("no reply")
sys.exit(1)
