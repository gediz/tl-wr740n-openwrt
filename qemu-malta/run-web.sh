#!/bin/bash
# SPDX-License-Identifier: MIT
# Host side for the web UI tests: isolated runner container owrt-qemu-web, then tests-web.sh inside it.
# Usage: ./run-web.sh [RAM_MB]    Keys and overlay values: keys.inc.sh
set -e
Q=$(cd "$(dirname "$0")" && pwd)
. $Q/keys.inc.sh
mkdir -p $Q/logs
docker build -q -t owrt-qemu-malta $Q/docker-qemu >/dev/null
docker build -q -t owrt-qemu-web $Q/docker-qemu-web >/dev/null
# --network none: only loopback; QEMU's tap/bridge and user-mode NIC live inside the container.
docker rm -f owrt-qemu-web >/dev/null 2>&1 || true
docker run -d --init --name owrt-qemu-web --network none --cpus 4 --memory 2g \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v $Q:/work "${KEYMOUNTS[@]}" owrt-qemu-web sleep infinity >/dev/null
docker exec "${TESTENV[@]}" owrt-qemu-web /work/tests-web.sh "${1:-32}"
