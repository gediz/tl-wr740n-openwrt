#!/bin/bash
# SPDX-License-Identifier: MIT
# Ablation run: build seeds/abl/s1..s8 one after another from a clean tree and measure each.
# s7 and s8 also get the first-round kernel trim (ablation/kernel-trim-r1.config). That early trim still
# lacks SPI_AR934X and AR8216_PHY: those kernels do NOT boot on the router. Size numbers only.
# Overwrites src/target/linux/ath79/tiny/config-default; re-apply openwrt-source.patch afterwards
# (git -C src checkout target/linux/ath79/tiny/config-default && git -C src apply openwrt-source.patch).
B=$(cd "$(dirname "$0")" && pwd); S=$B/seeds/abl; CD=$B/src/target/linux/ath79/tiny/config-default
C=${CONTAINER:-owrt-src-2410}; J=${JOBS:-$(nproc)}
for s in s1 s2 s3 s4 s5 s6 s7 s8; do
  cp $B/ablation/config-default.orig $CD
  case $s in s7|s8) cat $B/ablation/kernel-trim-r1.config >> $CD;; esac
  docker exec $C bash -c "cd /src && make -j$J clean >/dev/null 2>&1"
  $B/step.sh abl-$s $S/$s
done
echo ABLATION-DONE
