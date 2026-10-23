################################################################################
#
# livi
#
################################################################################

# LIVI with the F1C200s port (the f1c200s branch of the owner's fork of
# f-io/LIVI): the Slint UI on DRM/KMS, which also decodes and shows the phone's
# video; gst-host for audio and handing the video over; livi-core; and the root
# helper. Like fastcarplay it TRACKS THE BRANCH TIP: the head is resolved to a
# commit sha at build time, so a moved branch is a new version. For local work
# point output/local.mk at a checkout instead (no network needed for the source):
#   LIVI_OVERRIDE_SRCDIR = /path/to/LIVI
LIVI_BRANCH = f1c200s
ifeq ($(LIVI_OVERRIDE_SRCDIR),)
LIVI_VERSION = $(shell git ls-remote https://github.com/mbt28/LIVI.git \
	refs/heads/$(LIVI_BRANCH) 2>/dev/null | cut -c1-40)
ifeq ($(BR2_PACKAGE_LIVI),y)
ifeq ($(LIVI_VERSION),)
$(error livi: cannot resolve the $(LIVI_BRANCH) branch of mbt28/LIVI -- network down? Or set LIVI_OVERRIDE_SRCDIR in local.mk)
endif
endif
endif
LIVI_SITE = https://github.com/mbt28/LIVI.git
LIVI_SITE_METHOD = git
LIVI_LICENSE = GPL-3.0+
LIVI_LICENSE_FILES = LICENSE
# Desktop GStreamer bundles, LIVI Link firmware and screenshots: ~590 MiB the
# build never reads.
LIVI_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = \
	--exclude=/assets/gstreamer --exclude=/assets/livi-link --exclude=/docs

LIVI_DEPENDENCIES = \
	ffmpeg \
	gst1-plugins-base \
	gstreamer1 \
	host-pkgconf \
	host-rustc \
	openssl \
	$(BR2_CMAKE_HOST_DEPENDENCY)

# Kernel features LIVI cannot run without (see fastcarplay.mk for why they are
# declared here): IPv6 link-local and the iPhone's NCM interface for wired
# CarPlay, /dev/i2c-N for the MFi coprocessor, evdev for touch and keys.
define LIVI_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_INET)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IPV6)
	$(call KCONFIG_ENABLE_OPT,CONFIG_I2C)
	$(call KCONFIG_ENABLE_OPT,CONFIG_I2C_CHARDEV)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_NET_DRIVERS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_USBNET)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_NET_CDC_NCM)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_IPHETH)
	$(call KCONFIG_ENABLE_OPT,CONFIG_INPUT_EVDEV)
endef

# Crates are fetched by cargo at build time into a cache that persists under
# DL_DIR (only the first build needs the network), as slint-cpp does. LIVI's own
# embedded profile: opt-level z, fat LTO, one codegen unit, panic=abort.
LIVI_CARGO_ENV = \
	$(PKG_CARGO_ENV) \
	HOST_CC="$(HOSTCC)" \
	HOST_CXX="$(HOSTCXX)" \
	CARGO_TARGET_DIR=$(@D)/target \
	PKG_CONFIG="$(PKG_CONFIG_HOST_BINARY)" \
	PKG_CONFIG_ALLOW_CROSS=1 \
	OPENSSL_DIR="$(STAGING_DIR)/usr" \
	OPENSSL_NO_VENDOR=1
LIVI_CARGO = cd $(@D)/native && $(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) \
	$(LIVI_CARGO_ENV) cargo build --locked --profile embedded
LIVI_OUT = $(@D)/target/$(RUSTC_TARGET_NAME)/embedded

# One cargo run per feature set: the UI without winit, on DRM/KMS with the
# video; gst-host handing the video to the UI instead of a compositor.
define LIVI_BUILD_CMDS
	$(LIVI_CARGO) -p livi-ui --no-default-features --features kms-video
	$(LIVI_CARGO) -p livi-core -p livi-helperd
	$(LIVI_CARGO) -p gst-video-host --features ui-planes
endef

# The layout livi-core expects under LIVI_RESOURCES (and the UI next to it),
# with the templates it checks its udev rule against. The rule itself is
# installed here: on a desktop livi-core would put it in place through sudo.
define LIVI_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(LIVI_OUT)/LIVI $(TARGET_DIR)/opt/livi/livi-ui
	$(INSTALL) -D -m 0755 $(LIVI_OUT)/livi-core \
		$(TARGET_DIR)/opt/livi/resources/core/livi-core
	$(INSTALL) -D -m 0755 $(LIVI_OUT)/livi-helperd \
		$(TARGET_DIR)/opt/livi/resources/driver/livi-helperd
	$(INSTALL) -D -m 0755 $(LIVI_OUT)/livi-gst-host \
		$(TARGET_DIR)/opt/livi/resources/gst-host/livi-gst-host
	$(INSTALL) -D -m 0644 $(@D)/assets/linux/99-LIVI.rules.template \
		$(TARGET_DIR)/opt/livi/resources/99-LIVI.rules.template
	$(INSTALL) -D -m 0755 $(@D)/assets/linux/livi-touch-filter \
		$(TARGET_DIR)/opt/livi/resources/livi-touch-filter
	$(INSTALL) -D -m 0644 $(@D)/assets/linux/99-LIVI.rules.template \
		$(TARGET_DIR)/etc/udev/rules.d/99-LIVI.rules
	$(INSTALL) -D -m 0755 $(@D)/assets/linux/livi-touch-filter \
		$(TARGET_DIR)/usr/local/lib/livi/livi-touch-filter
	$(INSTALL) -D -m 0644 $(@D)/f1c200s/config.json $(TARGET_DIR)/opt/livi/config.json
	$(INSTALL) -D -m 0755 $(@D)/f1c200s/start.sh $(TARGET_DIR)/opt/livi/start.sh
endef

$(eval $(generic-package))
