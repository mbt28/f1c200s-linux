#!/bin/sh
#
# Write this bundle to the board's SPI NAND. RUN THIS ON THE BOARD, from Linux
# booted off the SD card -- the image already ships mtd-utils.
#
#   ./flash-nand.sh            write everything
#   ./flash-nand.sh --no-uboot write kernel + rootfs only, leave mtd0 alone
#   ./flash-nand.sh --verify   verify what is already on the chip, write nothing
#
# WHY NOT FROM U-BOOT: U-Boot's `mtd bad` reports 514 bad blocks on this chip
# where Linux reports zero -- three perfectly contiguous runs totalling 64 MiB,
# which is not what real bad blocks look like and is contradicted by the vendor
# firmware happily using 118 MiB of the part. Its bad-block marker
# interpretation disagrees with vendor-written data. A write driven off that map
# would skip 64 MiB of good blocks, and bad-block skipping is the entire reason
# nandwrite is safer than dd. Linux's view is the correct one, so flash here.
#
# NEVER use dd on a NAND device: it does not skip bad blocks.
set -e

cd "$(dirname "$0")"

UBOOT=u-boot-sunxi-with-spl.bin
SQUASH=rootfs.squashfs

DO_UBOOT=yes
VERIFY_ONLY=no
case "$1" in
--no-uboot) DO_UBOOT=no ;;
--verify)   VERIFY_ONLY=yes ;;
"")         ;;
*) echo "usage: $0 [--no-uboot|--verify]" >&2; exit 2 ;;
esac

for t in flash_erase nandwrite nanddump mtdinfo; do
	command -v $t >/dev/null || { echo "ERROR: $t missing (mtd-utils)" >&2; exit 1; }
done

# The partitions come from the DTS (patch 0024). If they are absent the kernel
# shows one whole-chip mtd0 and writing by partition would silently target the
# bootloader area -- so refuse rather than guess.
[ -e /dev/mtd3 ] || {
	echo "ERROR: /dev/mtd3 missing -- the NAND is not partitioned." >&2
	echo "       This kernel predates patch 0024. Writing by partition is unsafe;" >&2
	echo "       refusing. Boot an image built after that patch." >&2
	exit 1
}

sz() { printf '%d' "$(( $(sed -n "s/^mtd$1: \([0-9a-f]*\).*/0x\1/p" /proc/mtd) ))" 2>/dev/null; }

verify() { # verify <mtdN> <file>
	_n=$1; _f=$2
	_len=$(wc -c < "$_f")
	nanddump --quiet --length="$_len" -f /tmp/.rb.$$ /dev/mtd$_n 2>/dev/null
	if [ "$(sha256sum < /tmp/.rb.$$ | cut -d' ' -f1)" = "$(sha256sum < "$_f" | cut -d' ' -f1)" ]; then
		echo "  mtd$_n verified against $_f"
		rm -f /tmp/.rb.$$
	else
		rm -f /tmp/.rb.$$
		echo "  mtd$_n MISMATCH against $_f" >&2
		return 1
	fi
}

if [ "$VERIFY_ONLY" = yes ]; then
	echo "verifying (writing nothing):"
	verify 1 kernel.itb
	verify 2 "$SQUASH"
	[ "$DO_UBOOT" = no ] || verify 0 "$UBOOT"
	echo "done."
	exit 0
fi

# ORDER IS DELIBERATE: rootfs first, bootloader LAST. Every step before mtd0
# leaves the board still bootable from whatever is currently in mtd0, so an
# interruption mid-run is recoverable. mtd0 is the one write that, if it goes
# wrong, leaves the board FEL-only -- still recoverable (hold BOOT with no SD
# card and sunxi-fel talks to it) but no longer self-booting.

echo "== mtd2 rootfs =="
flash_erase --quiet /dev/mtd2 0 0
nandwrite -p /dev/mtd2 "$SQUASH"
verify 2 "$SQUASH"

echo "== mtd3 overlay (erase only) =="
# Deliberately not written: jffs2 formats itself on first mount of an erased
# partition, so an image would be wasted bytes. Erasing also discards whatever
# the vendor firmware left there.
flash_erase --quiet /dev/mtd3 0 0

echo "== mtd1 kernel =="
flash_erase --quiet /dev/mtd1 0 0
nandwrite -p /dev/mtd1 kernel.itb
verify 1 kernel.itb

if [ "$DO_UBOOT" = yes ]; then
	echo "== mtd0 u-boot (last, and the risky one) =="
	flash_erase --quiet /dev/mtd0 0 0
	nandwrite -p /dev/mtd0 "$UBOOT"
	verify 0 "$UBOOT"
else
	echo "== mtd0 u-boot SKIPPED (--no-uboot) =="
fi

sync
echo
echo "done. Remove the SD card and reboot to boot from NAND."
echo "If it does not come up: hold BOOT with no SD card inserted and the board"
echo "enters FEL, where sunxi-fel can load a working U-Boot into RAM."
