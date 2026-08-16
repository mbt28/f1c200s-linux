#!/bin/sh
#
# Write this bundle to the board's SPI NAND. RUN THIS ON THE BOARD, from Linux
# booted off the SD card -- the image already ships mtd-utils.
#
#   ./flash-nand.sh            write kernel + rootfs, KEEP the existing u-boot
#   ./flash-nand.sh --uboot    also overwrite mtd0 -- see the warning below
#   ./flash-nand.sh --verify   verify what is already on the chip, write nothing
#
# THE DEFAULT LEAVES mtd0 ALONE, ON PURPOSE. Mainline U-Boot's SPL cannot boot
# from SPI NAND on suniv -- arch/arm/mach-sunxi/board.c has, verbatim:
#
#     /* SPI NAND is not supported yet. */
#     case SUNIV_BOOTED_FROM_NAND:
#             return SUNXI_INVALID_BOOT_SOURCE;
#
# which falls through to FEL. So writing OUR u-boot to mtd0 produces a board
# that cannot boot from NAND at all. The stock bootloader already drives this
# chip and already loads a FIT from mtd1 -- verbatim from its environment:
#
#     nand_kernel_offset=0x80000        (= our mtd1)
#     nand_kernel_length=0x580000       (= our mtd1 size)
#     kernel_addr_r=0x81000000
#     nand_boot=mtd read spi-nand0 ${kernel_addr_r} \
#               ${nand_kernel_offset} ${nand_kernel_length}; bootm ${kernel_addr_r};
#
# which is exactly the layout this bundle targets, because we mirrored it.
#
# It does NOT, however, supply a kernel command line: there is no "bootargs"
# variable anywhere in that environment. The vendor's cmdline comes from the
# chosen node of the DTB inside its own FIT. Ours therefore has to come from
# the chosen node of OUR dtb -- see patch 0024. Do not "fix" a boot failure
# here by editing this script; the cmdline is not this script's to set.
#
# Only pass --uboot once a U-Boot with an SPL SPI-NAND reader exists. The
# vendor's own SPL proves it is possible on this silicon (strings on the stock
# mtd0 show "U-Boot SPL 2020.07" with "SPI-NAND: GigaDevice GD5F1GQ4UAYIG"),
# but mainline does not have it.
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

DO_UBOOT=no
VERIFY_ONLY=no
case "$1" in
--uboot)  DO_UBOOT=yes ;;
--verify) VERIFY_ONLY=yes ;;
"")       ;;
*) echo "usage: $0 [--uboot|--verify]" >&2; exit 2 ;;
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

verify() { # verify <mtdN> <file>
	_n=$1; _f=$2
	_len=$(wc -c < "$_f")
	# STREAMED, not staged to a file. nanddump writes to stdout when given no
	# -f, which matters here: /tmp is an 8 MiB tmpfs (see post-build.sh) and
	# the rootfs readback is ~30 MiB, so a temp file would hit ENOSPC and, with
	# set -e, abort the run immediately after the mtd2 write.
	if [ "$(nanddump --quiet --length="$_len" /dev/mtd$_n | sha256sum | cut -d" " -f1)" \
	   = "$(sha256sum < "$_f" | cut -d" " -f1)" ]; then
		echo "  mtd$_n verified against $_f"
	else
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
	echo "== mtd0 u-boot LEFT ALONE (stock bootloader kept; --uboot overrides) =="
fi

sync
echo
echo "done. Remove the SD card and reboot to boot from NAND."
echo "If it does not come up: hold BOOT with no SD card inserted and the board"
echo "enters FEL, where sunxi-fel can load a working U-Boot into RAM."
