#!/usr/bin/env bash
# Configure + build the F1C200s image with our external tree.
# Wraps Buildroot: `make BR2_EXTERNAL=<this repo>:<lehu>/packaging/buildroot
# O=<output> <defconfig> && make`.
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

# Our changes to Buildroot itself (patches/buildroot/, e.g. ffmpeg 8.0.3),
# applied to the checkout with git apply. A patch already applied is skipped;
# one that applies neither way stops the build. Older trees carry a libudev
# line that build.sh used to add to ffmpeg.mk with sed (the "f1c200s-udev-fix"
# marker; patch 0001 now has it): it is taken out first.
FFMK="$BR/package/ffmpeg/ffmpeg.mk"
[ -f "$FFMK" ] && sed -i '/f1c200s-udev-fix/d' "$FFMK"
for p in "$HERE"/patches/buildroot/*.patch; do
	[ -e "$p" ] || continue
	if git -C "$BR" apply --reverse --check "$p" 2>/dev/null; then
		continue
	fi
	echo ">>> patch Buildroot: $(basename "$p")"
	git -C "$BR" apply "$p" || { echo "!! $(basename "$p") does not apply to $BR"; exit 1; }
done

# Two external trees: this repository (CARPLAY) and LEHU's packaging (LEHU).
LEHU_EXT="$HERE/$LEHU_DIR/packaging/buildroot"
[ -f "$LEHU_EXT/external.desc" ] || { echo "!! LEHU's packaging missing ($LEHU_EXT) — run scripts/fetch-sources.sh first"; exit 1; }

MAKE=(make -C "$BR" BR2_EXTERNAL="$HERE:$LEHU_EXT" O="$OUT")

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
