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
DEFCFG="$HERE/configs/$DEFCONFIG"
[ -d "$BR" ] || { echo "!! Buildroot missing — run scripts/fetch-sources.sh first"; exit 1; }

# Kernel/U-Boot versions come from the defconfig (the value Buildroot actually
# uses) -- single source of truth, no config.env copy to drift out of sync.
def_val() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$DEFCFG"; }
LINUX_VERSION="$(def_val BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE)"
UBOOT_VERSION="$(def_val BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE)"

# Buildroot's ffmpeg.mk has no udev knob, but we force --enable-libudev (the
# v4l2-request hwaccel enumerates /dev/mediaX via libudev). Without a declared
# dependency, a clean parallel build can configure ffmpeg before libudev-zero is
# staged -> "libudev not found using pkg-config". Inject the build-order dep.
# (external.mk is included after package/*/*.mk, so it can't add this itself.)
FFMK="$BR/package/ffmpeg/ffmpeg.mk"
if [ -f "$FFMK" ] && ! grep -q 'f1c200s-udev-fix' "$FFMK"; then
	echo ">>> patch ffmpeg.mk: add libudev-zero build-order dependency"
	sed -i '/eval .*autotools-package/i FFMPEG_DEPENDENCIES += $(if $(BR2_PACKAGE_LIBUDEV_ZERO),libudev-zero) # f1c200s-udev-fix' "$FFMK"
fi

MAKE=(make -C "$BR" BR2_EXTERNAL="$HERE" O="$OUT")

# (Re)apply the defconfig when .config is missing OR when the defconfig / config.env
# is newer than it. Buildroot never regenerates .config from a defconfig on its own,
# so without this a version bump (e.g. the 7.1.x move) would be silently ignored and
# the stale kernel rebuilt. Applying the defconfig refreshes .config's mtime, so an
# unchanged tree won't re-apply (and won't clobber a later `menuconfig`).
if [ ! -f "$OUT/.config" ] || [ "$DEFCFG" -nt "$OUT/.config" ] || [ "$HERE/config.env" -nt "$OUT/.config" ]; then
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
