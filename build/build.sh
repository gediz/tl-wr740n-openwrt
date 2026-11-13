#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the TL-WR740N v5 image from source in a Docker container. Run on the host.
#   ./build.sh            squashfs sysupgrade + factory images
#   ./build.sh initramfs  initramfs-kernel.bin (cpio xz-compressed inside the kernel). Its squashfs images differ
#                         slightly from the plain build (rebuilt kmods); flash sysupgrade/factory from the plain build.
# Environment: see prepare-files.sh (LAN_IP, AUTHORIZED_KEYS, ...), plus
#   OPENWRT_TAG (default v24.10.8), JOBS (default nproc), CONTAINER (default owrt-src-2410).
# Output: src/bin/targets/ath79/tiny/. Then run ./measure.sh and ../tools/dtbcheck.py on the result.
set -e
B=$(cd "$(dirname "$0")" && pwd)
TAG=${OPENWRT_TAG:-v24.10.8}
J=${JOBS:-$(nproc)}
C=${CONTAINER:-owrt-src-2410}
mkdir -p $B/logs
[ "$(id -u)" = 1000 ] || echo "warning: host UID $(id -u) is not 1000; the container user ubuntu (UID 1000) may not be able to write to the source tree" >&2
[ -d $B/src/.git ] || git clone --branch $TAG --depth 1 https://github.com/openwrt/openwrt.git $B/src
docker build -t owrt-build-2410 $B/docker
docker inspect $C >/dev/null 2>&1 || \
  docker run -d --name $C -v $B/src:/src -v $B:/out owrt-build-2410 sleep infinity
docker start $C >/dev/null
docker exec $C bash -c 'cd /src && ./scripts/feeds update -a && ./scripts/feeds install -a'
# Applied once: a second run finds it applied (--check fails) and skips it.
git -C $B/src apply --check $B/openwrt-source.patch 2>/dev/null && git -C $B/src apply $B/openwrt-source.patch
$B/prepare-files.sh $B/src/files
if [ "$1" = initramfs ]; then cp $B/seeds/initramfs-xz.seed $B/src/.config; else cp $B/diffconfig.txt $B/src/.config; fi
docker exec $C bash -c "cd /src && make defconfig && make -j$J download && make -j$J"
ls -l $B/src/bin/targets/ath79/tiny/
