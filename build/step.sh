#!/bin/bash
# SPDX-License-Identifier: MIT
# usage: step.sh LABEL [seedfile]  -> defconfig from seed (if given), build, measure.
# Needs the tree and container that build.sh sets up. Log: logs/build-LABEL.log
B=$(cd "$(dirname "$0")" && pwd)
C=${CONTAINER:-owrt-src-2410}; J=${JOBS:-$(nproc)}
L=$1; SEED=$2
mkdir -p $B/logs
[ -n "$SEED" ] && cp $SEED $B/src/.config
rm -f $B/src/bin/targets/ath79/tiny/*.bin
docker exec $C bash -c "cd /src && make defconfig >/dev/null 2>&1 && make -j$J > /out/logs/build-$L.log 2>&1; echo rc=\$? >> /out/logs/build-$L.log"
tail -1 $B/logs/build-$L.log
grep -h "too big\|ERROR" $B/logs/build-$L.log | head -3
$B/measure.sh $L
