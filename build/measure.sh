#!/bin/bash
# SPDX-License-Identifier: MIT
# usage: measure.sh LABEL  (run on the host after a build) -> prints sizes, appends to logs/sizes.tsv
# margin = what is left of the 4Mlzma budget for kernel + rootfs (see docs/size-budget.md).
B=$(cd "$(dirname "$0")" && pwd)
S=$B/src
mkdir -p $B/logs
KD=$(ls -d $S/build_dir/target-mips_24kc_musl/linux-ath79_tiny 2>/dev/null)
K=$KD/tplink_tl-wr740n-v5-kernel.bin
R=$KD/root.squashfs
ks=$(stat -c %s "$K" 2>/dev/null || echo 0)
rs=$(stat -c %s "$R" 2>/dev/null || echo 0)
vm=$(stat -c %s $KD/linux-*/vmlinux 2>/dev/null|| echo 0)
tot=$((ks+rs))
# mktplinkfw counts the 512-byte header against 3,670,016 and rounds the kernel up to 4 bytes (mktplinkfw.c:316-321).
lim=3669504
ks4=$(( (ks + 3) / 4 * 4 ))
SU=$(ls $S/bin/targets/ath79/tiny/*tl-wr740n-v5*sysupgrade.bin 2>/dev/null)
printf "%s\tkernel=%d\trootfs=%d\ttotal=%d\tmargin=%d\tvmlinux=%d\tsysupgrade=%s\n" "$1" $ks $rs $tot $((lim-ks4-rs)) $vm "$( [ -n "$SU" ] && stat -c %s $SU || echo none)" | tee -a $B/logs/sizes.tsv
