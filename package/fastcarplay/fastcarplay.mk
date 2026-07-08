################################################################################
#
# fastcarplay
#
################################################################################

# FastCarPlay is fetched from the user's own repo (not vendored here) and
# TRACKS THE BRANCH TIP (owner's choice 2026-07-08): the branch HEAD is
# resolved to a commit sha at build time, so a moved branch = new version =
# fresh download, while an unchanged branch reuses the cached tarball.
# (A plain branch name as VERSION would cache the first tarball forever --
# the classic Buildroot trap.) Needs network when the package is built; for
# a frozen release, put a commit sha in FASTCARPLAY_VERSION instead.
# For local hacking, point at a working clone:
#   FASTCARPLAY_VERSION = local
#   FASTCARPLAY_SITE = /path/to/FastCarPlay
#   FASTCARPLAY_SITE_METHOD = local
FASTCARPLAY_BRANCH = f1c200s-cedrus
FASTCARPLAY_VERSION = $(shell git ls-remote \
	https://github.com/mbt28/FastCarPlay.git \
	refs/heads/$(FASTCARPLAY_BRANCH) 2>/dev/null | cut -c1-40)
ifeq ($(BR2_PACKAGE_FASTCARPLAY),y)
ifeq ($(FASTCARPLAY_VERSION),)
$(error fastcarplay: cannot resolve the $(FASTCARPLAY_BRANCH) branch tip -- network down?)
endif
endif
FASTCARPLAY_SITE = $(call github,mbt28,FastCarPlay,$(FASTCARPLAY_VERSION))
FASTCARPLAY_LICENSE = GPL-3.0
FASTCARPLAY_LICENSE_FILES = LICENSE
FASTCARPLAY_DEPENDENCIES = \
	bluez5_utils \
	dbus \
	ffmpeg \
	host-pkgconf \
	libcedarc \
	libdrm \
	libusb \
	openssl \
	sdl2 \
	sdl2_ttf

# Build BOTH HW decoders; the one used is chosen at runtime by the settings
# (cedar-decode / cedrus-decode) to match /etc/ve-driver:
#   USE_CEDAR=1  -> CedarDecoder  (libcedarc + /dev/cedar_dev) -- the working path
#   USE_CEDRUS=1 -> CedrusDecoder (ffmpeg v4l2-request, mainline) -- working
#   USE_AA_WIRELESS=1 -> protocol = aa-wireless (BT bootstrap via BlueZ/D-Bus
#   + the SoftAP; needs `ap on` + bluetoothd/dbus running at runtime)
define FASTCARPLAY_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D) \
		PKG_CONFIG="$(PKG_CONFIG_HOST_BINARY)" \
		HOST_XXD="/usr/bin/xxd" \
		USE_CEDAR=1 \
		USE_CEDRUS=1 \
		USE_AA_WIRELESS=1 \
		BUILD_TYPE=release \
		release
endef

define FASTCARPLAY_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) \
		DESTDIR="$(TARGET_DIR)" \
		PREFIX=/usr \
		SYSCONFDIR=/etc \
		install
	# Ship EVERY preset the app repo provides (settings_*.txt): cedar/cedrus
	# for the `carplay` alias (picked by /etc/ve-driver), plus the wireless/AA
	# variants (settings_cedrus_wireless.txt, settings_cedrus_aa.txt, ...).
	# Wildcard on purpose -- the package tracks the branch tip, so new presets
	# ship automatically without touching this file.
	$(foreach f,$(wildcard $(@D)/settings_*.txt), \
		$(INSTALL) -D -m 0644 $(f) \
			$(TARGET_DIR)/etc/fastcarplay/$(notdir $(f))$(sep))
endef

$(eval $(generic-package))
