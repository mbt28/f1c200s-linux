#!/usr/bin/env bash
# Configure + build the F1C200s image with our external tree.
# Wraps Buildroot: `make BR2_EXTERNAL=<this repo> O=<output> <defconfig> && make`.
#
# Usage:
#   scripts/build.sh                 # defconfig (if needed) + full build
#   scripts/build.sh menuconfig      # any Buildroot target is forwarded
#   scripts/build.sh linux-rebuild
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$HERE/config.env"

BR="$HERE/$BUILDROOT_DIR"
OUT="$HERE/$OUTPUT_DIR"
[ -d "$BR" ] || { echo "!! Buildroot missing — run scripts/fetch-sources.sh first"; exit 1; }

MAKE=(make -C "$BR" BR2_EXTERNAL="$HERE" O="$OUT")

# First-time (or after config.env change): apply our defconfig.
if [ ! -f "$OUT/.config" ]; then
	echo ">>> applying $DEFCONFIG"
	"${MAKE[@]}" "$DEFCONFIG"
fi

if [ "$#" -gt 0 ]; then
	echo ">>> make $*"
	exec "${MAKE[@]}" "$@"
fi

echo ">>> building (this downloads Linux $LINUX_VERSION + U-Boot $UBOOT_VERSION)"
"${MAKE[@]}"

echo
echo "Image: $OUT/images/sdcard.img"
echo "Flash: sudo dd if=$OUT/images/sdcard.img of=/dev/sdX bs=1M conv=fsync   # pick the right /dev/sdX!"
