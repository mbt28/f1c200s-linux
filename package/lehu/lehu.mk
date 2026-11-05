################################################################################
#
# lehu
#
################################################################################

# Tracks the branch tip, as fastcarplay and livi do: the head is resolved
# to a commit sha at build time, so a moved branch is a new version. For
# local work point output/local.mk at a checkout:
#   LEHU_OVERRIDE_SRCDIR = /path/to/lehu
LEHU_BRANCH = main
ifeq ($(LEHU_OVERRIDE_SRCDIR),)
LEHU_VERSION = $(shell git ls-remote https://github.com/mbt28/lehu.git \
	refs/heads/$(LEHU_BRANCH) 2>/dev/null | cut -c1-40)
ifeq ($(BR2_PACKAGE_LEHU),y)
ifeq ($(LEHU_VERSION),)
$(error lehu: cannot resolve the $(LEHU_BRANCH) branch of mbt28/lehu -- network down? Or set LEHU_OVERRIDE_SRCDIR in local.mk)
endif
endif
endif
LEHU_SITE = https://github.com/mbt28/lehu.git
LEHU_SITE_METHOD = git
LEHU_LICENSE = GPL-3.0+
LEHU_LICENSE_FILES = LICENSE NOTICE

LEHU_DEPENDENCIES = \
	alsa-lib \
	ffmpeg \
	host-pkgconf \
	host-rustc \
	openssl \
	opus

# What the program cannot run without (see fastcarplay.mk for why they are
# declared here): IPv6 link-local and the iPhone's NCM interface for wired
# CarPlay, /dev/i2c-N for the MFi coprocessor, evdev, uhid for BLE
# keyboards, RFCOMM for the wireless bootstraps.
define LEHU_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_INET)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IPV6)
	$(call KCONFIG_ENABLE_OPT,CONFIG_I2C)
	$(call KCONFIG_ENABLE_OPT,CONFIG_I2C_CHARDEV)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_NET_DRIVERS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_USBNET)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_NET_CDC_NCM)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_IPHETH)
	$(call KCONFIG_ENABLE_OPT,CONFIG_INPUT_EVDEV)
	$(call KCONFIG_ENABLE_OPT,CONFIG_UHID)
	$(call KCONFIG_ENABLE_OPT,CONFIG_BT_RFCOMM)
endef

# Crates are fetched by cargo into a cache that persists under DL_DIR (only
# the first build needs the network). The workspace's release profile is
# the embedded one: opt-level z, fat LTO, one codegen unit, panic=abort,
# stripped. PKG_CARGO_ENV overrides the profile from the Buildroot config
# (16 codegen units, no LTO, its own opt-level), which makes the binary
# 60% bigger, so the profile is set again after it. The C helpers (the
# decoder, the camera's V4L2 shim, the AAC decoder) find ffmpeg through
# pkg-config.
LEHU_CARGO_ENV = \
	$(PKG_CARGO_ENV) \
	CARGO_PROFILE_RELEASE_OPT_LEVEL="z" \
	CARGO_PROFILE_RELEASE_LTO="fat" \
	CARGO_PROFILE_RELEASE_CODEGEN_UNITS="1" \
	CARGO_PROFILE_RELEASE_DEBUG="false" \
	HOST_CC="$(HOSTCC)" \
	CARGO_TARGET_DIR=$(@D)/target \
	PKG_CONFIG="$(PKG_CONFIG_HOST_BINARY)" \
	PKG_CONFIG_ALLOW_CROSS=1 \
	OPENSSL_DIR="$(STAGING_DIR)/usr" \
	OPENSSL_NO_VENDOR=1
LEHU_OUT = $(@D)/target/$(RUSTC_TARGET_NAME)/release

define LEHU_BUILD_CMDS
	cd $(@D) && $(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) \
		$(LEHU_CARGO_ENV) cargo build --locked --release -p lehu
endef

# This image (f1c200s-linux) runs LEHU as f1c, from its ~/.profile: the serial
# console logs f1c in (inittab) and the profile starts lehu in the foreground.
# So, unlike LEHU's draft (packaging/buildroot): no S99lehu, no lehu user, and
# neither its sudoers rule nor its D-Bus policy (f1c has sudo; BlueZ answers
# it). LEHU keeps its state in ~f1c/.lehu.
define LEHU_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(LEHU_OUT)/lehu $(TARGET_DIR)/usr/bin/lehu
	$(INSTALL) -D -m 0644 $(LEHU_PKGDIR)/files/lehu.toml \
		$(TARGET_DIR)/etc/lehu/lehu.toml
	$(INSTALL) -D -m 0644 $(LEHU_PKGDIR)/files/99-lehu.rules \
		$(TARGET_DIR)/etc/udev/rules.d/99-lehu.rules
endef

# hostapd's config holds the network's passphrase, which LEHU hands to the
# phones: readable by f1c's group, by no one else.
define LEHU_PERMISSIONS
	/etc/hostapd.conf f 0640 root f1c - - - - -
endef

$(eval $(generic-package))
