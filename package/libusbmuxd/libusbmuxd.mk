################################################################################
#
# libusbmuxd
#
################################################################################

LIBUSBMUXD_VERSION = 2.1.0
LIBUSBMUXD_SOURCE = libusbmuxd-$(LIBUSBMUXD_VERSION).tar.bz2
LIBUSBMUXD_SITE = https://github.com/libimobiledevice/libusbmuxd/releases/download/$(LIBUSBMUXD_VERSION)
LIBUSBMUXD_INSTALL_STAGING = YES
LIBUSBMUXD_LICENSE = LGPL-2.1+
LIBUSBMUXD_LICENSE_FILES = COPYING
LIBUSBMUXD_DEPENDENCIES = host-pkgconf libplist libimobiledevice-glue

$(eval $(autotools-package))
