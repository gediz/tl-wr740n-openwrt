#!/bin/bash
# SPDX-License-Identifier: MIT
# Host side: build-output copy, isolated runner container, then tests.sh inside it.
# Usage: ./run.sh [RAM_MB]    Keys and overlay values: keys.inc.sh
set -e
Q=$(cd "$(dirname "$0")" && pwd)
. $Q/keys.inc.sh
B=$Q/src/bin/targets/malta/be
mkdir -p $Q/images $Q/logs
cp $B/openwrt-malta-be-vmlinux.elf $Q/images/vmlinux.elf
cp $B/openwrt-malta-be-rootfs-ext4.img* $Q/images/
ln -sf $(cd $Q/images && ls openwrt-malta-be-rootfs-ext4.img* | head -1) $Q/images/rootfs-ext4.img
docker build -q -t owrt-qemu-malta $Q/docker-qemu >/dev/null
# --network none: the container has only loopback; QEMU's tap/bridge and user-mode NIC live inside it.
docker rm -f owrt-qemu-malta >/dev/null 2>&1 || true
docker run -d --init --name owrt-qemu-malta --network none --cpus 4 --memory 2g \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v $Q:/work "${KEYMOUNTS[@]}" owrt-qemu-malta sleep infinity >/dev/null
docker exec "${TESTENV[@]}" owrt-qemu-malta /work/tests.sh "${1:-32}"
