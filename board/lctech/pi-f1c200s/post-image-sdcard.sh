#!/bin/sh
# Add the extended partition p4 and the swap area p5 to sdcard.img, after
# genimage (genimage-sdcard.cfg) has written p1-p3:
#   p4  1197056, extended (0x0f), holding p5 alone (S02maps grows it)
#   p5  1199104, 64 MiB, swap (0x82): 1 MiB on, its extended boot record at p4's start
# These are the sectors of a card shared with LEHU OS (lehu-os/docs/dual-boot.md).
# genimage can make the extended partition itself, but one sector before its
# first logical partition: parted then refuses to grow it ("Unable to satisfy
# all constraints"), which S02maps does on the first boot to add p6 and p7.
#
# The swap area is an emergency backstop. zram (priority 100) is the real swap;
# this is priority 10 and should never be touched -- see S03swap. It ships
# unformatted: S03swap runs mkswap on first boot, after checking the partition
# really has 131072 sectors.
#
# The image ENDS at p4's extended boot record, and the table declares p5 past
# EOF. That is desirable (the image does not grow, flashing writes 64 MiB less,
# dd and bmaptool do not care) but it means the CARD MUST BE >= ~650 MiB, and
# some GUI flashers may warn. S02maps wants about 5.7 GiB for p6 and p7.
#
# Buildroot runs this after support/scripts/genimage.sh, with BINARIES_DIR as
# $1 (BR2_ROOTFS_POST_IMAGE_SCRIPT).
set -eu

IMG="${1:?BINARIES_DIR}/sdcard.img"
SFDISK="${HOST_DIR:?}/sbin/sfdisk"
P4_START=1197056
P5_START=1199104
P5_SECTORS=131072

[ -f "$IMG" ] || { echo "post-image-sdcard: no $IMG" >&2; exit 1; }
# genimage's image ends where p3 does.
end=$(($(stat -c %s "$IMG") / 512))
[ "$end" = "$P4_START" ] || {
	echo "post-image-sdcard: $IMG ends at sector $end, not at p4's start ($P4_START): genimage-sdcard.cfg changed?" >&2
	exit 1
}

# sfdisk refuses partitions past the end of the file: grow it (sparse) for
# the write, then cut it back to just past the extended boot record.
truncate -s $(((P5_START + P5_SECTORS) * 512)) "$IMG"
printf '%s\n' "$P4_START,$((P5_START + P5_SECTORS - P4_START)),f" "$P5_START,$P5_SECTORS,82" |
	"$SFDISK" --append --no-reread --no-tell-kernel -q "$IMG"
truncate -s $(((P4_START + 1) * 512)) "$IMG"

table=$("$SFDISK" -d "$IMG")
echo "$table" | grep -q "start= *$P4_START, size= *$((P5_START + P5_SECTORS - P4_START)), type=f$" &&
	echo "$table" | grep -q "start= *$P5_START, size= *$P5_SECTORS, type=82$" || {
	echo "post-image-sdcard: p4/p5 not as expected:" >&2
	echo "$table" >&2
	exit 1
}
echo "post-image-sdcard: p4 (extended) at $P4_START, p5 (swap) at $P5_START"
