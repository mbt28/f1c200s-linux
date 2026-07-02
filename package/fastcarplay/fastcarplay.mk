################################################################################
#
# fastcarplay
#
################################################################################

# FastCarPlay is fetched from the user's own repo (not vendored here). Pin a
# commit for reproducible builds. For local hacking, point at a working clone:
#   FASTCARPLAY_VERSION = local
#   FASTCARPLAY_SITE = /path/to/FastCarPlay
#   FASTCARPLAY_SITE_METHOD = local
# f1c200s-cedrus branch HEAD: CedrusDecoder/DEFE integration + the install target.
FASTCARPLAY_VERSION = b63caec9463b3cf64b8bfe83d05e6a660f6a731f
FASTCARPLAY_SITE = $(call github,mbt28,FastCarPlay,$(FASTCARPLAY_VERSION))
FASTCARPLAY_LICENSE = GPL-3.0
FASTCARPLAY_LICENSE_FILES = LICENSE
FASTCARPLAY_DEPENDENCIES = \
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
#   USE_CEDRUS=1 -> CedrusDecoder (ffmpeg v4l2-request, mainline) -- research/broken
define FASTCARPLAY_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D) \
		PKG_CONFIG="$(PKG_CONFIG_HOST_BINARY)" \
		HOST_XXD="/usr/bin/xxd" \
		USE_CEDAR=1 \
		USE_CEDRUS=1 \
		BUILD_TYPE=release \
		release
endef

define FASTCARPLAY_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) \
		DESTDIR="$(TARGET_DIR)" \
		PREFIX=/usr \
		SYSCONFDIR=/etc \
		install
	# Ship both presets; the `carplay` alias picks the one matching /etc/ve-driver:
	#   settings_cedar.txt  -> cedar-decode=true,  renderer=drm  (working)
	#   settings_cedrus.txt -> cedrus-decode=true, renderer=none (research)
	$(INSTALL) -D -m 0644 $(@D)/settings_cedar.txt \
		$(TARGET_DIR)/etc/fastcarplay/settings_cedar.txt
	$(INSTALL) -D -m 0644 $(@D)/settings_cedrus.txt \
		$(TARGET_DIR)/etc/fastcarplay/settings_cedrus.txt
endef

$(eval $(generic-package))
