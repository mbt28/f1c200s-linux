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
# Fetched via git (not the github tarball helper): third_party/lvgl is a git
# SUBMODULE and GitHub tarballs never contain submodules -- the git method +
# GIT_SUBMODULES pulls it in. The sha-as-version caching above still applies.
FASTCARPLAY_SITE = https://github.com/mbt28/FastCarPlay.git
FASTCARPLAY_SITE_METHOD = git
FASTCARPLAY_GIT_SUBMODULES = YES
FASTCARPLAY_LICENSE = GPL-3.0
FASTCARPLAY_LICENSE_FILES = LICENSE
FASTCARPLAY_DEPENDENCIES = \
	bluez5_utils \
	dbus \
	ffmpeg \
	host-pkgconf \
	libcedarc \
	libdrm \
	libimobiledevice \
	libplist \
	libusb \
	openssl \
	sdl2 \
	sdl2_ttf

# Kernel features the app cannot run without. Declared HERE, not just in the
# board fragment, so they are a real dependency of the package instead of
# something inherited from whatever defconfig a board happens to use: Buildroot
# applies these to the kernel .config (after the fragments, before olddefconfig)
# whenever this package is enabled. Buildroot's own Kconfig cannot express a
# Linux config symbol, so Config.in can only document them -- this is the
# mechanism that actually enforces it. board/lctech/pi-f1c200s/post-build.sh
# then fails the build if either symbol did not survive olddefconfig.
#
# IPV6: both CarPlay backends hand the phone an IPv6 link-local address to
#   connect back to -- CarPlayStartSession { ip = fe80::..%usb0 | %wlan0,
#   port = 7000 }. There is no IPv4 form of that handshake, so without IPv6 the
#   :7000 AF_INET6 listener fails EAFNOSUPPORT and CarPlay cannot start at all.
#   (Android Auto is IPv4 over AOAP and unaffected.) INET is listed because
#   IPV6 lives inside "if INET" in net/Kconfig -- enabling IPV6 alone would be
#   silently dropped by olddefconfig on a kernel without it.
# I2C_CHARDEV: the MFi authentication coprocessor is driven from userspace as
#   /dev/i2c-N (mfi-i2c-bus). I2C is its menu gate, same reasoning as INET.
# IPHETH + CDC_NCM: these are what give wired CarPlay its usb0 link -- ipheth
#   switches the iPhone into NCM mode, cdc_ncm creates usb0, and usb0's fe80::
#   address is what CarPlayStartSession points the phone at. USBNET is
#   cdc_ncm's dependency and USB_NET_DRIVERS the menu gate for both.
define FASTCARPLAY_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_INET)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IPV6)
	$(call KCONFIG_ENABLE_OPT,CONFIG_I2C)
	$(call KCONFIG_ENABLE_OPT,CONFIG_I2C_CHARDEV)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_NET_DRIVERS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_USBNET)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_NET_CDC_NCM)
	$(call KCONFIG_ENABLE_OPT,CONFIG_USB_IPHETH)
endef

# Build BOTH HW decoders; since app d58e335 the app picks its video path at
# runtime itself (video-path = auto probes the V4L2 decoder nodes + DRM
# master; S20ve-select still decides which KERNEL driver is loaded via
# /etc/ve-driver):
#   USE_CEDAR=1  -> CedarDecoder  (libcedarc + /dev/cedar_dev) -- the working path
#   USE_CEDRUS=1 -> CedrusDecoder (ffmpeg v4l2-request, mainline) -- working
#   USE_AA_WIRELESS=1 -> protocol = aa-wireless (BT bootstrap via BlueZ/D-Bus
#   + the SoftAP; needs `ap on` + bluetoothd/dbus running at runtime)
#   USE_LVGL=1 -> on-device UI (vendored third_party/lvgl submodule + the
#   EEZ-generated screens in src/ui; compiled out entirely without it)
#   USE_CP_WIRED=1 -> protocol = carplay-wired (config-6 usbmux + carkit iAP2
#   via libimobiledevice + libplist; CarPlay over the USB-NCM link -- no Wi-Fi/BT)
define FASTCARPLAY_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D) \
		PKG_CONFIG="$(PKG_CONFIG_HOST_BINARY)" \
		HOST_XXD="/usr/bin/xxd" \
		USE_CEDAR=1 \
		USE_CEDRUS=1 \
		USE_AA_WIRELESS=1 \
		USE_CP_WIRED=1 \
		USE_CP_WIRELESS=1 \
		USE_LVGL=1 \
		BUILD_TYPE=release \
		release
endef

define FASTCARPLAY_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) \
		DESTDIR="$(TARGET_DIR)" \
		PREFIX=/usr \
		SYSCONFDIR=/etc \
		install
	# Ship the app's preset files (settings_*.txt): since app d58e335 that is
	# settings_drm.txt (head units -- what S99carplay boots) and
	# settings_desktop.txt (desktop dev; inert on the device). Wildcard on
	# purpose -- the package tracks the branch tip, so new presets ship
	# automatically without touching this file. The commented settings.txt
	# reference is installed by `make install` above (not matched by the glob).
	$(foreach f,$(wildcard $(@D)/settings_*.txt), \
		$(INSTALL) -D -m 0644 $(f) \
			$(TARGET_DIR)/etc/fastcarplay/$(notdir $(f))$(sep))
endef

$(eval $(generic-package))
