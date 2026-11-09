################################################################################
#
# ostree
#
################################################################################

# The version LEHU OS runs (meta-oe's ostree_2026.1.bb). curl only for
# file:// remotes: ostree cannot pull without curl or soup, even from a
# local folder, and LEHU brings the update to the card itself.
OSTREE_VERSION = 2026.1
OSTREE_SOURCE = libostree-$(OSTREE_VERSION).tar.xz
OSTREE_SITE = https://github.com/ostreedev/ostree/releases/download/v$(OSTREE_VERSION)
OSTREE_LICENSE = LGPL-2.1+
OSTREE_LICENSE_FILES = COPYING
OSTREE_INSTALL_STAGING = YES

OSTREE_COMMON_CONF_OPTS = \
	--with-crypto=glib \
	--with-openssl \
	--with-curl \
	--without-soup \
	--without-soup3 \
	--without-gpgme \
	--without-avahi \
	--without-composefs \
	--without-ed25519-libsodium \
	--without-libarchive \
	--without-libsystemd \
	--without-selinux \
	--without-smack \
	--without-dracut \
	--without-mkinitcpio \
	--disable-rofiles-fuse \
	--disable-man \
	--disable-gtk-doc \
	--disable-introspection

OSTREE_DEPENDENCIES = \
	e2fsprogs \
	host-bison \
	host-pkgconf \
	libcurl \
	libglib2 \
	openssl \
	util-linux \
	xz \
	zlib

OSTREE_CONF_OPTS = \
	$(OSTREE_COMMON_CONF_OPTS) \
	--with-libmount \
	--with-static-compiler='$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) $(TARGET_LDFLAGS)'

# The board needs the ostree command, its library and ostree-prepare-root.
define OSTREE_REMOVE_EXTRAS
	rm -rf $(TARGET_DIR)/usr/lib/ostree/ostree-grub-generator \
		$(TARGET_DIR)/usr/libexec/libostree/grub2-15_ostree \
		$(TARGET_DIR)/etc/grub.d \
		$(TARGET_DIR)/usr/share/bash-completion
endef
OSTREE_POST_INSTALL_TARGET_HOOKS += OSTREE_REMOVE_EXTRAS

# On the build host, for the image (package/ostreefs) and for
# scripts/make-update.sh. It runs under fakeroot in the image: the same two
# options as OpenEmbedded's native build under pseudo.
HOST_OSTREE_DEPENDENCIES = \
	host-bison \
	host-e2fsprogs \
	host-libcurl \
	host-libglib2 \
	host-openssl \
	host-pkgconf \
	host-xz \
	host-zlib

# Not through pkg-config: host-libcurl finds the build machine's brotli and
# zstd and names them in its libcurl.pc, where the host's pkg-config cannot
# look. The shared library finds them itself.
HOST_OSTREE_CONF_ENV = \
	OT_DEP_CURL_CFLAGS="-I$(HOST_DIR)/include" \
	OT_DEP_CURL_LIBS="-L$(HOST_DIR)/lib -lcurl"

HOST_OSTREE_CONF_OPTS = \
	$(OSTREE_COMMON_CONF_OPTS) \
	--without-libmount \
	--enable-wrpseudo-compat \
	--disable-otmpfile

$(eval $(autotools-package))
$(eval $(host-autotools-package))
