#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# usage: dtbcheck.py sysupgrade.bin outdir [module.ko ...]
# Static driver check for a trimmed kernel: unpack the LZMA kernel from a TP-Link v1 image, cut out the
# appended device tree (d00dfeed), and for every node print whether each of its compatible strings appears
# in vmlinux (outside the DTB) or in one of the given modules. An enabled node whose strings are all NONE
# has no driver. Needs dtc. Writes outdir/{vmlinux.bin,board.dtb,board.dts,rootfs.bin}.
import sys, lzma, struct, subprocess, re, os
img, out = sys.argv[1], sys.argv[2]
mods = sys.argv[3:]
os.makedirs(out, exist_ok=True)
data = open(img, 'rb').read()
# TP-Link v1 header is 0x200 bytes; kernel length at 0x84, rootfs offset/length at 0x88/0x8c (big-endian)
klen = struct.unpack('>I', data[0x84:0x88])[0]
rofs = struct.unpack('>I', data[0x88:0x8c])[0]
rlen = struct.unpack('>I', data[0x8c:0x90])[0]
open(out + '/rootfs.bin', 'wb').write(data[rofs:rofs + rlen])
kernel = data[0x200:0x200 + klen]
d = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE)
vm = d.decompress(kernel)
open(out + '/vmlinux.bin', 'wb').write(vm)
off = vm.find(b'\xd0\x0d\xfe\xed')
tot = struct.unpack('>I', vm[off + 4:off + 8])[0]
open(out + '/board.dtb', 'wb').write(vm[off:off + tot])
print(f'hdr_kernel_len={klen} rootfs_ofs=0x{rofs:x} hdr_rootfs_len={rlen} decompressed={len(vm)} dtb_offset=0x{off:x} dtb_size={tot}')
rest = vm[:off] + vm[off + tot:]
modblobs = {m: open(m, 'rb').read() for m in mods}
dts = subprocess.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', out + '/board.dtb'],
                     capture_output=True, text=True).stdout
open(out + '/board.dts', 'w').write(dts)
# walk nodes
stack = []  # (path, disabled)
nodes = []  # path, compat list, enabled
for line in dts.splitlines():
    s = line.strip()
    m = re.match(r'^(?:[\w-]+:\s*)?([\w@,.+-]+|/)\s*\{$', s)
    if m:
        name = m.group(1)
        path = '/' if name == '/' else (stack[-1][0].rstrip('/') + '/' + name)
        stack.append([path, False, [], stack[-1][1] if stack else False])
        continue
    if s == '};':
        p, dis, comp, pdis = stack.pop()
        nodes.append((p, comp, not (dis or pdis)))
        continue
    if not stack:
        continue
    m = re.match(r'^status\s*=\s*"(\w+)"', s)
    if m and m.group(1) != 'okay':
        stack[-1][1] = True
    m = re.match(r'^compatible\s*=\s*(.*);$', s)
    if m:
        stack[-1][2] = [x for q in re.findall(r'"([^"]+)"', m.group(1)) for x in q.split('\\0')]
# propagate disabled: a node is disabled if any ancestor disabled
dis = {p for p, c, e in nodes if not e}
for p, comp, en in sorted(nodes):
    if not comp:
        continue
    anc_dis = any(p.startswith(d + '/') for d in dis)
    state = 'enabled' if en and not anc_dis else 'disabled'
    hits = []
    for c in comp:
        b = b'\0' + c.encode() + b'\0'
        where = []
        if b in rest:
            where.append('vmlinux')
        for mname, blob in modblobs.items():
            if b in blob:
                where.append(os.path.basename(mname))
        hits.append(f'{c}=[{",".join(where) or "NONE"}]')
    print(f'{state}\t{p}\t' + ' '.join(hits))
