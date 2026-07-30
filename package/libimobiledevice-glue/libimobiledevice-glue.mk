################################################################################
#
# libimobiledevice-glue
#
################################################################################

LIBIMOBILEDEVICE_GLUE_VERSION = 1.3.1
LIBIMOBILEDEVICE_GLUE_SOURCE = libimobiledevice-glue-$(LIBIMOBILEDEVICE_GLUE_VERSION).tar.bz2
LIBIMOBILEDEVICE_GLUE_SITE = https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/$(LIBIMOBILEDEVICE_GLUE_VERSION)
LIBIMOBILEDEVICE_GLUE_INSTALL_STAGING = YES
LIBIMOBILEDEVICE_GLUE_LICENSE = LGPL-2.1+
LIBIMOBILEDEVICE_GLUE_LICENSE_FILES = COPYING
LIBIMOBILEDEVICE_GLUE_DEPENDENCIES = host-pkgconf libplist

$(eval $(autotools-package))
