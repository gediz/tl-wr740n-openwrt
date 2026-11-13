#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the malta/be test image from scratch (plain: ../files-bench only, no web UI). Run on the host.
# Uses the owrt-build-2410 Docker image from ../build/docker. Overlay values: see ../build/prepare-files.sh.
set -e
Q=$(cd "$(dirname "$0")" && pwd)
C=${CONTAINER:-owrt-src-malta}; J=${JOBS:-$(nproc)}
[ "$(id -u)" = 1000 ] || echo "warning: host UID $(id -u) is not 1000; the container user ubuntu (UID 1000) may not be able to write to the source tree" >&2
[ -d $Q/src/.git ] || git clone --branch ${OPENWRT_TAG:-v24.10.8} --depth 1 https://github.com/openwrt/openwrt.git $Q/src
docker build -q -t owrt-build-2410 $Q/../build/docker >/dev/null
docker inspect --type container $C >/dev/null 2>&1 || \
  docker run -d --name $C -v $Q/src:/src -v $Q:/out owrt-build-2410 sleep infinity
docker start $C >/dev/null
docker exec $C bash -c 'cd /src && ./scripts/feeds update -a && ./scripts/feeds install -a'
git -C $Q/src apply --check $Q/malta-source.patch 2>/dev/null && git -C $Q/src apply $Q/malta-source.patch
NO_WEB=1 $Q/../build/prepare-files.sh $Q/src/files
chmod -R go-w $Q/src/package $Q/src/target
cp $Q/diffconfig-malta.txt $Q/src/.config
docker exec $C bash -c "cd /src && make defconfig && make -j$J download && make -j$J"
ls -l $Q/src/bin/targets/malta/be/
