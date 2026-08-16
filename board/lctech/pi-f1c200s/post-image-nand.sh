#!/bin/sh
#
# Post-image hook #2: build the SPI NAND artifacts alongside the SD card image.
#
# Runs after Buildroot has produced output/images/{zImage,*.dtb,rootfs.squashfs,
# u-boot-sunxi-with-spl.bin}. Emits nand-bundle.tar.gz containing everything the
# board needs plus the script that writes it.
#
# ARGUMENT HANDLING, and why it looks odd: BR2_ROOTFS_POST_SCRIPT_ARGS is shared
# by every script phase (pre-build, post-build, post-fakeroot AND post-image) and
# cannot be varied per script. It currently holds "-c <genimage cfg>" for
# genimage.sh, so this script receives those stray args too and must ignore
# them. post-build.sh already does the same. $1 is BINARIES_DIR, as Buildroot
# passes it to every post-image script.
set -e

BINARIES_DIR="${1:-${BINARIES_DIR}}"
BOARD_DIR="$(dirname "$0")"
OUT="${BINARIES_DIR}/nand"

MKIMAGE="${HOST_DIR}/bin/mkimage"
[ -x "${MKIMAGE}" ] || {
	echo "ERROR: ${MKIMAGE} missing" >&2
	echo "       Needed to build kernel.itb for the NAND's mtd1 partition." >&2
	echo "       Fix: BR2_PACKAGE_HOST_UBOOT_TOOLS=y +" >&2
	echo "            BR2_PACKAGE_HOST_UBOOT_TOOLS_FIT_SUPPORT=y in the defconfig." >&2
	exit 1
}

DTB="suniv-f1c200s-lctech-pi.dtb"
UBOOT="u-boot-sunxi-with-spl.bin"
SQUASH="rootfs.squashfs"

for f in zImage "${DTB}" "${SQUASH}" "${UBOOT}"; do
	[ -f "${BINARIES_DIR}/${f}" ] || {
		echo "ERROR: ${BINARIES_DIR}/${f} not found -- cannot build the NAND bundle" >&2
		[ "${f}" = "${SQUASH}" ] && \
			echo "       (rootfs.squashfs needs BR2_TARGET_ROOTFS_SQUASHFS=y)" >&2
		exit 1
	}
done

rm -rf "${OUT}"
mkdir -p "${OUT}"

# mkimage resolves /incbin/ paths relative to the .its, so assemble in one dir.
cp "${BINARIES_DIR}/zImage" "${BINARIES_DIR}/${DTB}" "${BOARD_DIR}/kernel.its" "${OUT}/"
( cd "${OUT}" && "${MKIMAGE}" -f kernel.its kernel.itb >/dev/null )
rm -f "${OUT}/zImage" "${OUT}/${DTB}" "${OUT}/kernel.its"

cp "${BINARIES_DIR}/${UBOOT}" "${BINARIES_DIR}/${SQUASH}" "${OUT}/"
cp "${BOARD_DIR}/flash-nand.sh" "${OUT}/"
chmod +x "${OUT}/flash-nand.sh"

# --- fit checks: refuse to ship a bundle that cannot be written -------------
# Partition sizes come from the DTS (patch 0024) and mirror the vendor layout.
check_fit() {
	_f="${OUT}/$1"; _max="$2"; _part="$3"
	_sz=$(wc -c < "${_f}")
	if [ "${_sz}" -gt "${_max}" ]; then
		echo "ERROR: $1 is ${_sz} bytes, larger than mtd${_part} (${_max})" >&2
		echo "       It cannot be flashed. Shrink it or change the layout" >&2
		echo "       (patches/linux-lctech/0024-*.patch defines the partitions)." >&2
		exit 1
	fi
	printf '  %-26s %9d bytes  (mtd%s holds %d, %d spare)\n' \
		"$1" "${_sz}" "${_part}" "${_max}" "$((_max - _sz))"
}

echo "NAND bundle:"
check_fit "${UBOOT}"  524288    0
check_fit kernel.itb  5767168   1
check_fit "${SQUASH}" 67108864  2

# --- manifest ---------------------------------------------------------------
{
	echo "# NAND artifacts for the Lctech Pi F1C200s (GigaDevice 128 MiB SPI NAND)"
	echo "# Built $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "#"
	echo "# target   offset      size        file"
	echo "# mtd0     0x00000000  512 KiB     ${UBOOT}   (NOT written by default)"
	echo "# mtd1     0x00080000  5.5 MiB     kernel.itb"
	echo "# mtd2     0x00600000  64 MiB      ${SQUASH}"
	echo "# mtd3     0x04600000  48 MiB      (erased only -- jffs2 self-formats)"
	echo "#"
	echo "# Flash with ./flash-nand.sh from Linux booted off the SD card."
	echo "# By default it writes mtd1/mtd2/mtd3 and KEEPS the stock bootloader in"
	echo "# mtd0: mainline U-Boot\'s SPL cannot boot SPI NAND on suniv, so replacing"
	echo "# it would give a FEL-only board. The stock loader already reads a FIT from"
	echo "# 0x80000 and takes its cmdline from the FIT\'s own device tree, which is"
	echo "# why the kernel .dts carries chosen/bootargs (patch 0024)."
	echo "# Do NOT flash from U-Boot: its bad-block map is wrong on this chip"
	echo "# (514 false positives where Linux reports zero)."
	echo
	cd "${OUT}" && sha256sum "${UBOOT}" kernel.itb "${SQUASH}" flash-nand.sh
} > "${OUT}/MANIFEST.txt"

tar -czf "${BINARIES_DIR}/nand-bundle.tar.gz" -C "${BINARIES_DIR}" nand
echo "  -> ${BINARIES_DIR}/nand-bundle.tar.gz"
