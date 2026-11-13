#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# usage: imgcheck.py factory.bin outdir
# Checks the TP-Link v1 header (size, hw_id, md5, offsets), the deadc0de markers, and counts
# "vlan_filtering" in the decompressed kernel (must be 1 or more, see docs/dead-lan.md).
# Writes outdir/vmlinux.bin and outdir/rootfs.squashfs.
import sys, struct, hashlib, lzma, os
img, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
d = open(img, 'rb').read()
be = lambda o: struct.unpack('>I', d[o:o+4])[0]
print('size', len(d), hex(len(d)), 'ok' if len(d) == 0x3c0000 else 'BAD')
print('+0x40', d[0x40:0x48].hex())
print('vendor', d[0x04:0x1c].rstrip(b'\0').decode(), 'version', d[0x1c:0x40].rstrip(b'\0').decode())
load, entry, fwlen = be(0x74), be(0x78), be(0x7c)
kofs, klen, rofs, rlen = be(0x80), be(0x84), be(0x88), be(0x8c)
print('load', hex(load), 'entry', hex(entry), 'fw_length', hex(fwlen))
print('kernel ofs', hex(kofs), 'len', hex(klen), klen, ' rootfs ofs', hex(rofs), 'len', hex(rlen), rlen, 'end', hex(rofs+rlen))
# header md5: md5 of whole image with md5 field (0x4c..0x5c) replaced by md5salt_normal,
# TP-Link's fixed header salt (the same constant as in OpenWrt's mktplinkfw)
salt = bytes.fromhex('dc d7 3a a5 c3 95 98 fb dd f9 e7 f4 0e ae 47 38'.replace(' ', ''))
stored = d[0x4c:0x5c]
calc = hashlib.md5(d[:0x4c] + salt + d[0x5c:fwlen]).digest()
print('header md5', 'valid' if calc == stored else 'INVALID', stored.hex())
k = d[kofs:kofs+klen]
vm = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(k)
open(out + '/vmlinux.bin', 'wb').write(vm)
print('lzma props', hex(k[0]), 'dict', struct.unpack('<I', k[1:5])[0], 'decompressed', len(vm))
print('vlan_filtering hits', vm.count(b'vlan_filtering'))
open(out + '/rootfs.squashfs', 'wb').write(d[rofs:rofs+rlen])
print('rootfs magic', d[rofs:rofs+4])
marks = [hex(i) for i in range(rofs+rlen, len(d)) if i % 0x1000 == 0 and d[i:i+4] == b'\xde\xad\xc0\xde']
print('deadc0de at', marks)
tail = bytearray(d[rofs+rlen:])
for m in marks:
    o = int(m, 16) - (rofs+rlen)
    tail[o:o+4] = b'\xff' * 4
padstart = rofs + rlen
# squashfs is padded to 4k? count non-ff bytes after the rootfs
nonff = [i for i, b in enumerate(tail) if b != 0xff]
print('non-0xff bytes after rootfs (excluding markers):', len(nonff), (hex(padstart+nonff[0]), hex(padstart+nonff[-1])) if nonff else '')
