# QEMU malta test only (not in the router image): the "sysupgrade image" is
# openwrt-malta-be-rootfs-ext4.img.gz, written over /dev/sda.
platform_check_image() {
	[ "$(get_magic_word "$1" cat)" = 1f8b ] || { echo "not a gzip image"; return 1; }
	[ "$( (get_image "$1" | dd bs=1 skip=1080 count=2 | hexdump -v -n 2 -e '2/1 "%02x"') 2>/dev/null)" = 53ef ] \
		|| { echo "no ext4 superblock"; return 1; }
	return 0
}
platform_do_upgrade() {
	get_image "$1" | dd of=/dev/sda bs=64k
	sync
}
platform_copy_config() {
	mount -t ext4 /dev/sda /mnt && cp -f "$UPGRADE_BACKUP" /mnt/sysupgrade.tgz && sync
	umount /mnt
}
