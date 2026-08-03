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

# Buildroot's git download archives the tree WITHOUT .git, and a git checkout
# has no .tarball-version -- so configure.ac's git-version-gen finds neither
# and autoreconf dies with "PACKAGE_VERSION is not defined". Write the file an
# official `make dist` tarball would carry, in git-version-gen's own fallback
# format: <NEWS version>-git-<short sha>. (The release-tarball siblings
# libusbmuxd/-glue/libtatsu ship it already and don't need this.)
define LIBIMOBILEDEVICE_SET_TARBALL_VERSION
	echo "$$(sed -n '1s/^Version //p' $(@D)/NEWS)-git-$$(echo $(LIBIMOBILEDEVICE_VERSION) | cut -c1-7)" \
		> $(@D)/.tarball-version
endef
LIBIMOBILEDEVICE_POST_EXTRACT_HOOKS += LIBIMOBILEDEVICE_SET_TARBALL_VERSION

$(eval $(autotools-package))
