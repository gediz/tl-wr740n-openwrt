#!/bin/bash
# SPDX-License-Identifier: MIT
# Host side: run one suite on images-routernet/ (build-routernet.sh) in its own runner container (--network none).
# Usage: run-routernet.sh base|web|f2 [RAM_MB]   (default 32)
#   base: tests.sh (T1 to T10)
#   web : tests-web.sh (W1 to W18, S1 to S9)
#   f2  : tests-f2.sh (F2 migration: unit cases, keep-settings sysupgrade from an old-style config)
# Each suite gets its own container and network namespace, so the three can run at the same time.
# Logs go to logs/routernet/. images/, images-web/ and the plain logs are not touched.
set -e
S=$1; MEM=${2:-32}
case "$S" in base) T=tests.sh ;; web) T=tests-web.sh ;; f2) T=tests-f2.sh ;; *) echo "usage: $0 base|web|f2 [RAM_MB]"; exit 1 ;; esac
Q=$(cd "$(dirname "$0")" && pwd)
. $Q/keys.inc.sh
O=$Q/images-routernet; L=$Q/logs/routernet
[ -f $O/vmlinux.elf ] || { echo "no image in $O, run build-routernet.sh first"; exit 1; }
mkdir -p $L
docker build -q -t owrt-qemu-malta $Q/docker-qemu >/dev/null
docker build -q -t owrt-qemu-web $Q/docker-qemu-web >/dev/null
C=owrt-qemu-rn-$S
docker rm -f $C >/dev/null 2>&1 || true
docker run -d --init --name $C --network none --cpus 4 --memory 2g \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v $O:/work/images:ro -v $O:/work/images-web:ro -v $L:/work/logs \
  -v $Q/$T:/opt/$T:ro -v $Q/f2:/opt/f2:ro -v $Q/../files-bench:/opt/files-bench:ro \
  "${KEYMOUNTS[@]}" \
  owrt-qemu-web sleep infinity >/dev/null
rc=0
docker exec "${TESTENV[@]}" $C /opt/$T $MEM || rc=$?
docker rm -f $C >/dev/null
exit $rc
