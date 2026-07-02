#!/usr/bin/env bash
# Fetch the upstream trees this repo customizes but does NOT vendor:
#   - Buildroot (which itself downloads the Linux kernel + U-Boot during build)
#   - the Cedar VE+ION kernel driver (from the user's cedar repo)
#
# Idempotent: re-running updates the checkouts to the pinned versions.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$HERE/config.env"

# Kernel/U-Boot versions are the defconfig's (single source of truth); read for the banner.
DEFCFG="$HERE/configs/$DEFCONFIG"
def_val() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$DEFCFG"; }
# Kernel version (banner only): parse the pinned tarball URL, else CUSTOM_VERSION_VALUE.
LINUX_VERSION="$(sed -n 's|^BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION=.*/linux-\([0-9][0-9.]*\)\.tar.*|\1|p' "$DEFCFG")"
[ -n "$LINUX_VERSION" ] || LINUX_VERSION="$(def_val BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE)"
UBOOT_VERSION="$(def_val BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE)"

# --- Buildroot ------------------------------------------------------------
BR="$HERE/$BUILDROOT_DIR"
if [ ! -d "$BR/.git" ]; then
	echo ">>> cloning Buildroot $BUILDROOT_VERSION"
	git clone --depth 1 --branch "$BUILDROOT_VERSION" "$BUILDROOT_GIT" "$BR" \
		|| git clone "$BUILDROOT_GIT" "$BR"
fi
echo ">>> checking out Buildroot $BUILDROOT_VERSION"
git -C "$BR" fetch --depth 1 origin "$BUILDROOT_VERSION" 2>/dev/null || git -C "$BR" fetch --tags
git -C "$BR" checkout -q "$BUILDROOT_VERSION" 2>/dev/null \
	|| { echo "!! Buildroot ref '$BUILDROOT_VERSION' not found -- fix BUILDROOT_VERSION in config.env"; exit 1; }

# --- Cedar VE + ION driver (BSP decode path) ------------------------------
CEDAR="$HERE/cedar/src"
if [ ! -d "$CEDAR/.git" ]; then
	echo ">>> cloning cedar ($CEDAR_GIT@$CEDAR_REF)"
	git clone --branch "$CEDAR_REF" "$CEDAR_GIT" "$CEDAR" \
		|| git clone "$CEDAR_GIT" "$CEDAR"
fi
echo ">>> updating cedar to $CEDAR_REF"
git -C "$CEDAR" fetch origin "$CEDAR_REF"
git -C "$CEDAR" checkout -q "$CEDAR_REF"
git -C "$CEDAR" pull -q --ff-only origin "$CEDAR_REF" 2>/dev/null || true

cat <<EOF

Sources ready:
  Buildroot : $BR ($(git -C "$BR" describe --tags --always 2>/dev/null || echo '?'))
  Cedar     : $CEDAR ($(git -C "$CEDAR" rev-parse --short HEAD 2>/dev/null || echo '?'))
  Kernel    : $LINUX_VERSION  (downloaded by Buildroot at build time)
  U-Boot    : $UBOOT_VERSION  (downloaded by Buildroot at build time)

Next: scripts/build.sh
EOF
