#!/usr/bin/env bash
# Fetch the upstream trees this repo customizes but does NOT vendor:
#   - Buildroot (which itself downloads the Linux kernel + U-Boot during build)
#   - LEHU, for its Buildroot package (packaging/buildroot, an external tree)
#
# Idempotent: re-running updates the checkouts to the pinned versions.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$HERE/config.env"

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
	|| { echo "!! Buildroot tag $BUILDROOT_VERSION not found; staying on default branch"; }

# --- LEHU's packaging (a second external tree, packaging/buildroot) --------
LEHU="$HERE/$LEHU_DIR"
if [ -L "$LEHU" ]; then
	echo ">>> LEHU: $LEHU links to $(readlink "$LEHU"), left as it is"
elif [ ! -d "$LEHU/.git" ]; then
	echo ">>> cloning LEHU ($LEHU_BRANCH)"
	git clone --depth 1 --branch "$LEHU_BRANCH" "$LEHU_GIT" "$LEHU"
else
	echo ">>> updating LEHU ($LEHU_BRANCH)"
	git -C "$LEHU" fetch --depth 1 origin "$LEHU_BRANCH"
	git -C "$LEHU" checkout -q --detach FETCH_HEAD
fi
[ -f "$LEHU/packaging/buildroot/external.desc" ] \
	|| { echo "!! $LEHU has no packaging/buildroot/external.desc"; exit 1; }

cat <<EOF

Sources ready:
  Buildroot : $BR ($(git -C "$BR" describe --tags --always 2>/dev/null || echo '?'))
  Kernel    : $LINUX_VERSION  (downloaded by Buildroot at build time)
  U-Boot    : $UBOOT_VERSION  (downloaded by Buildroot at build time)
  LEHU      : $LEHU/packaging/buildroot ($(git -C "$LEHU" rev-parse --short HEAD 2>/dev/null || echo '?'))

Next: scripts/build.sh
EOF
