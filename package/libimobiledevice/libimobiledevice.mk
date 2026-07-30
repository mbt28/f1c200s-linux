################################################################################
#
# libimobiledevice
#
################################################################################

# There has been no release since 1.3.0 (2023); iOS 17+/26 support and the
# libtatsu dependency are git-only, so track the master tip (the branch HEAD is
# resolved to a commit sha at build time -- same sha-as-version approach the
# fastcarplay package uses, so a moved branch = fresh download and an unchanged
# branch reuses the cached tarball). Pin a specific sha in _VERSION for a
# reproducible build. Needs network when the package is fetched.
LIBIMOBILEDEVICE_VERSION = $(shell git ls-remote \
	https://github.com/libimobiledevice/libimobiledevice.git \
	refs/heads/master 2>/dev/null | cut -c1-40)
ifeq ($(BR2_PACKAGE_LIBIMOBILEDEVICE),y)
ifeq ($(LIBIMOBILEDEVICE_VERSION),)
$(error libimobiledevice: cannot resolve the master tip -- network down? pin a sha in LIBIMOBILEDEVICE_VERSION)
endif
endif
LIBIMOBILEDEVICE_SITE = https://github.com/libimobiledevice/libimobiledevice.git
LIBIMOBILEDEVICE_SITE_METHOD = git
LIBIMOBILEDEVICE_INSTALL_STAGING = YES
LIBIMOBILEDEVICE_LICENSE = LGPL-2.1+ (library), GPL-2.0+ (tools)
LIBIMOBILEDEVICE_LICENSE_FILES = COPYING COPYING.LESSER
LIBIMOBILEDEVICE_DEPENDENCIES = \
	host-pkgconf \
	libplist \
	libusbmuxd \
	libimobiledevice-glue \
	libtatsu \
	openssl
# git source has no configure script; regenerate it. No cython bindings (needs
# host-cython, not in Buildroot). We ship our own usbmux (cp_usbmux), so the
# usbmuxd daemon is not needed at runtime -- only the client library.
LIBIMOBILEDEVICE_AUTORECONF = YES
LIBIMOBILEDEVICE_CONF_OPTS = --without-cython

$(eval $(autotools-package))
