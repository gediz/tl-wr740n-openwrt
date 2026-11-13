#!/bin/bash
# SPDX-License-Identifier: MIT
# Flash cost of the web UI (busybox httpd with CGI + basic auth, plus ../files-web).
# Builds with seeds/probe-web-httpd.seed (output to src/bin-probe, src/bin is not touched): once without the
# web overlay (httpd only) and once with it, then rebuilds the normal config. Compare the rows in logs/sizes.tsv.
# Usage: probe-web.sh [full]   (full: skip the httpd-only build)
set -e
B=$(cd "$(dirname "$0")" && pwd)
C=${CONTAINER:-owrt-src-2410}; J=${JOBS:-$(nproc)}
mkdir -p $B/logs
run() {  # label seed
  cp $2 $B/src/.config
  docker exec $C bash -c "cd /src && make defconfig >/dev/null 2>&1 && make package/busybox/clean >/dev/null 2>&1 && make -j$J > /out/logs/build-$1.log 2>&1; echo rc=\$? >> /out/logs/build-$1.log"
  tail -1 $B/logs/build-$1.log
  $B/measure.sh $1
}
docker start $C >/dev/null
[ "$1" = full ] || { NO_WEB=1 $B/prepare-files.sh $B/src/files; run probe-web-httpd-only $B/seeds/probe-web-httpd.seed; }
$B/prepare-files.sh $B/src/files; run probe-web-full $B/seeds/probe-web-httpd.seed
docker exec $C bash -c 'cd /src && ls -l bin-probe/targets/ath79/tiny/ && staging_dir/host/bin/unsquashfs4 -l build_dir/target-mips_24kc_musl/linux-ath79_tiny/root.squashfs 2>/dev/null | grep -E "www-bench|benchweb|httpd"' || true
# back to the normal build
run final-recheck $B/diffconfig.txt
docker exec $C bash -c 'cd /src && make package/busybox/clean >/dev/null 2>&1'
