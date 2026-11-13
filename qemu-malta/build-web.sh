#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the malta/be image with the web UI (files-web + busybox httpd) into src/bin-web,
# copy it to images-web/, and make a second image (variant B) for the sysupgrade test.
# Does not touch src/bin or images/ (the plain test image). Run on the host after build.sh.
set -e
Q=$(cd "$(dirname "$0")" && pwd)
C=${CONTAINER:-owrt-src-malta}; J=${JOBS:-$(nproc)}
O=$Q/images-web
docker start $C >/dev/null
# overlay: files-bench + files-web (without its README) + test-only malta upgrade hooks
WIFI_OPEN=${WIFI_OPEN:-1} $Q/../build/prepare-files.sh $Q/src/files
cp -a $Q/files-malta-test/. $Q/src/files/
chmod -R go-w $Q/src/files
cp $Q/diffconfig-malta-web.txt $Q/src/.config
docker exec $C bash -c "cd /src && make defconfig && make package/busybox/clean && make -j$J" 2>&1 | tail -5
# back to the plain setup (build.sh state): files-bench only, busybox rebuilt on next plain build
docker exec $C bash -c 'cd /src && make package/busybox/clean' >/dev/null
NO_WEB=1 WIFI_OPEN=${WIFI_OPEN:-1} $Q/../build/prepare-files.sh $Q/src/files
cp $Q/diffconfig-malta.txt $Q/src/.config
B=$Q/src/bin-web/targets/malta/be
mkdir -p $O
cp $B/openwrt-malta-be-vmlinux.elf $O/vmlinux.elf
cp $B/openwrt-malta-be-rootfs-ext4.img.gz $B/openwrt-malta-be-default.manifest $O/
# variant B: same image plus /etc/fw-variant, to tell the images apart after sysupgrade
docker exec $C bash -c 'set -e; cd /tmp; zcat /out/images-web/openwrt-malta-be-rootfs-ext4.img.gz > b.ext4
  echo B > fw-variant; debugfs -w -R "write fw-variant /etc/fw-variant" b.ext4 >/dev/null
  debugfs -R "cat /etc/fw-variant" b.ext4; gzip -9n -c b.ext4 > /out/images-web/variant-b-rootfs-ext4.img.gz; rm -f b.ext4 fw-variant'
# overlay disk for the factory reset test (W15): the squashfs rootfs, then an empty ext4 "rootfs_data" at the
# next 64 KiB boundary. fstools (rootdisk) mounts it as the overlay, like JFFS2 on the router, so firstboot has
# an overlay to erase. The ext4 image boots without an overlay.
cp $B/openwrt-malta-be-rootfs-squashfs.img.gz $O/
docker exec $C bash -c 'set -e; cd /tmp; zcat /out/images-web/openwrt-malta-be-rootfs-squashfs.img.gz > o.img
  off=$(( ($(od -An -t u8 -j 40 -N 8 o.img) + 65535) / 65536 * 65536 )); truncate -s $off o.img
  truncate -s 16M ov.ext4; mkfs.ext4 -q -F -L rootfs_data ov.ext4; cat ov.ext4 >> o.img
  echo "overlay at $off"; gzip -9n -c o.img > /out/images-web/overlay-disk.img.gz; rm -f o.img ov.ext4'
ls -l $O
