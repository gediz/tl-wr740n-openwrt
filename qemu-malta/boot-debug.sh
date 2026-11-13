#!/bin/bash
# SPDX-License-Identifier: MIT
# Runs inside a runner container (see run.sh).
# Debug boot with a console reachable via fifos: echo 'cmd' > /tmp/run/con.in ; cat /tmp/run/con.out.log
MEM=${1:-32}; RUN=/tmp/run; IMG=/work/images
pkill -f qemu-system-mips; sleep 1; mkdir -p $RUN
zcat -f $IMG/rootfs-ext4.img > $RUN/rootfs.ext4
rm -f $RUN/con.in $RUN/con.out; mkfifo $RUN/con.in $RUN/con.out
qemu-system-mips -M malta -cpu 24Kc -m ${MEM}M -nographic -vga none -monitor none \
  -chardev pipe,id=c0,path=$RUN/con -serial chardev:c0 \
  -kernel $IMG/vmlinux.elf -append "root=/dev/sda rootwait console=ttyS0" \
  -drive file=$RUN/rootfs.ext4,format=raw,if=ide \
  -nic tap,ifname=tap0,script=no,downscript=no,model=pcnet,mac=52:54:00:50:00:01 \
  -nic user,model=pcnet,mac=52:54:00:50:00:02,net=10.0.2.0/24,hostfwd=tcp:127.0.0.1:2222-10.0.2.15:22 \
  </dev/null >$RUN/qemu.out 2>&1 &
cat $RUN/con.out > $RUN/con.out.log &
exec 3>$RUN/con.in; sleep infinity
