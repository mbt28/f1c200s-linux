################################################################################
#
# libtatsu
#
################################################################################

LIBTATSU_VERSION = 1.0.4
LIBTATSU_SOURCE = libtatsu-$(LIBTATSU_VERSION).tar.bz2
LIBTATSU_SITE = https://github.com/libimobiledevice/libtatsu/releases/download/$(LIBTATSU_VERSION)
LIBTATSU_INSTALL_STAGING = YES
LIBTATSU_LICENSE = LGPL-2.1+
LIBTATSU_LICENSE_FILES = COPYING
LIBTATSU_DEPENDENCIES = host-pkgconf libplist libcurl

$(eval $(autotools-package))
