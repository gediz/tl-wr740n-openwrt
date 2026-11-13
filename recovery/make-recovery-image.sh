#!/bin/bash
# SPDX-License-Identifier: MIT
# make-recovery-image.sh FULLDUMP [OUT]
# Cut the firmware partition (0x020000, 0x3c0000 bytes) out of a full 4 MiB flash dump of a TL-WR740N v5,
# so it can be served by recovery-flash.sh to put the router back exactly as it was when you dumped it.
# Also prints the product id at 0x1fd00 in the dump: that is what U-Boot compares with the image's +0x40.
# Default OUT: wr740nv5_tp_recovery.bin in the current directory.
# Make the dump first, from the running firmware (see ../docs/recovery.md), and keep a copy off your PC.
set -eu
D=${1:?usage: make-recovery-image.sh FULLDUMP [OUT]}
O=${2:-wr740nv5_tp_recovery.bin}
[ "$(stat -c %s "$D")" = 4194304 ] || { echo "$D is not 4 MiB (4194304 bytes): not a full dump of this board"; exit 1; }
flash_id=$(xxd -s 0x1fd00 -l 8 -p "$D")
echo "product id in the dump at 0x1fd00: $flash_id"
dd if="$D" of="$O" bs=64k skip=2 count=60 status=none
img_id=$(xxd -s 0x40 -l 8 -p "$O")
echo "product id in $O at +0x40:      $img_id"
echo "size: $(stat -c %s "$O") bytes (U-Boot accepts 3932160)"
[ "$flash_id" = "$img_id" ] || { echo "WARNING: the ids differ. U-Boot would refuse this file. Is the firmware in the dump a TP-Link v1 image?"; exit 1; }
sha256sum "$O"
echo "OK. Serve it with: ./recovery-flash.sh --iface <if> --file $O --sha256 <the sum above>"
