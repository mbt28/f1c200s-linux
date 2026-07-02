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
FASTCARPLAY_VERSION = f483456318344710d2890fc7ee0d67608892dea2
FASTCARPLAY_SITE = $(call github,mbt28,FastCarPlay,$(FASTCARPLAY_VERSION))
FASTCARPLAY_LICENSE = GPL-3.0
FASTCARPLAY_LICENSE_FILES = LICENSE
FASTCARPLAY_DEPENDENCIES = \
	ffmpeg \
	host-pkgconf \
	libdrm \
	libusb \
	openssl \
	sdl2 \
	sdl2_ttf

# USE_CEDRUS=1 swaps the avcodec Decoder for the mainline-cedrus CedrusDecoder
# (ffmpeg V4L2-Request hwaccel -> tiled-NV12 dma-buf -> DEFE), blob-free.
define FASTCARPLAY_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D) \
		PKG_CONFIG="$(PKG_CONFIG_HOST_BINARY)" \
		HOST_XXD="/usr/bin/xxd" \
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
	# F1C200s blob-free preset: mainline cedrus (ffmpeg v4l2-request) + DEFE.
	# The boot autorun launches this (settings_cedrus.txt, renderer=none).
	$(INSTALL) -D -m 0644 $(@D)/settings_cedrus.txt \
		$(TARGET_DIR)/etc/fastcarplay/settings_cedrus.txt
endef

$(eval $(generic-package))
