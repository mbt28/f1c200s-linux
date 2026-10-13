################################################################################
#
# slint-cpp
#
################################################################################

# Slint C++ API as a static library, software renderer only (the app blits
# into its own DRM dumb buffer). Rust comes from host-rust-bin, which ships
# a prebuilt armv5te-unknown-linux-gnueabi (soft-float) std. The hostbuilt
# slint-compiler is copied to $(HOST_DIR)/bin for the fastcarplay build.
SLINT_CPP_VERSION = 1.18.1
SLINT_CPP_SITE = $(call github,slint-ui,slint,v$(SLINT_CPP_VERSION))
SLINT_CPP_SUBDIR = api/cpp
SLINT_CPP_LICENSE = GPL-3.0-only or LicenseRef-Slint-Royalty-free-2.0 or \
	LicenseRef-Slint-Software-3.0
SLINT_CPP_LICENSE_FILES = LICENSE.md LICENSES/GPL-3.0-only.txt \
	LICENSES/LicenseRef-Slint-Royalty-free-2.0.md \
	LICENSES/LicenseRef-Slint-Software-3.0.md
SLINT_CPP_INSTALL_STAGING = YES
# Static library + headers only; nothing to ship in the rootfs.
SLINT_CPP_INSTALL_TARGET = NO
SLINT_CPP_DEPENDENCIES = host-rustc host-corrosion

# fontique 0.11.1 does not build on targets without 64-bit atomics; patch
# 0002 redirects cargo to an in-tree copy of the pristine crates.io sources
# (extracted below) and patch 0003 fixes it. The .crate file is a tar.gz.
SLINT_CPP_FONTIQUE_VERSION = 0.11.1
SLINT_CPP_EXTRA_DOWNLOADS = \
	https://static.crates.io/crates/fontique/fontique-$(SLINT_CPP_FONTIQUE_VERSION).crate

define SLINT_CPP_EXTRACT_FONTIQUE
	tar -xzf $(SLINT_CPP_DL_DIR)/fontique-$(SLINT_CPP_FONTIQUE_VERSION).crate \
		-C $(@D)
	mv $(@D)/fontique-$(SLINT_CPP_FONTIQUE_VERSION) $(@D)/fontique-patched
endef
SLINT_CPP_POST_EXTRACT_HOOKS += SLINT_CPP_EXTRACT_FONTIQUE

# Crates are fetched by cargo at build time into a cache that persists under
# DL_DIR (so only the first build needs the network). Proper buildroot-style
# vendoring is a follow-up. The release profile matches the embedded-Rust
# size recipe; it is what the F1C200s spike was measured with.
SLINT_CPP_CARGO_ENV = \
	CARGO_HOME=$(DL_DIR)/br-cargo-home \
	CARGO_TARGET_$(call UPPERCASE,$(RUSTC_TARGET_NAME))_LINKER=$(TARGET_CC) \
	CARGO_PROFILE_RELEASE_LTO=true \
	CARGO_PROFILE_RELEASE_OPT_LEVEL=z \
	CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
	CARGO_PROFILE_RELEASE_PANIC=abort

SLINT_CPP_CONF_ENV = $(SLINT_CPP_CARGO_ENV)
SLINT_CPP_MAKE_ENV = $(SLINT_CPP_CARGO_ENV)

SLINT_CPP_CONF_OPTS = \
	-DCMAKE_BUILD_TYPE=MinSizeRel \
	-DBUILD_SHARED_LIBS=OFF \
	-DCorrosion_DIR=$(HOST_DIR)/lib/cmake/Corrosion \
	-DRust_CARGO_TARGET=$(RUSTC_TARGET_NAME) \
	-DSLINT_FEATURE_RENDERER_SOFTWARE=ON \
	-DSLINT_FEATURE_BACKEND_WINIT=OFF \
	-DSLINT_FEATURE_BACKEND_QT=OFF \
	-DSLINT_FEATURE_BACKEND_LINUXKMS=OFF \
	-DSLINT_FEATURE_RENDERER_FEMTOVG=OFF \
	-DSLINT_FEATURE_RENDERER_SKIA=OFF \
	-DSLINT_FEATURE_INTERPRETER=OFF \
	-DSLINT_FEATURE_ACCESSIBILITY=OFF \
	-DSLINT_FEATURE_SYSTEM_TRAY=OFF \
	-DSLINT_FEATURE_TESTING=OFF \
	-DSLINT_LIBRARY_CARGO_FLAGS=--features=fontconfig-dlopen \
	-DDEFAULT_SLINT_EMBED_RESOURCES=embed-for-software-renderer

# slint-compiler is a host binary (corrosion hostbuild) that cmake installs
# next to the target lib. Copy -- not move -- it into HOST_DIR so the
# installed SlintConfig.cmake stays valid for cmake consumers.
define SLINT_CPP_INSTALL_SLINT_COMPILER
	cp $(STAGING_DIR)/usr/bin/slint-compiler $(HOST_DIR)/bin/slint-compiler
endef
SLINT_CPP_POST_INSTALL_STAGING_HOOKS += SLINT_CPP_INSTALL_SLINT_COMPILER

$(eval $(cmake-package))
