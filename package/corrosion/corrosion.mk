################################################################################
#
# host-corrosion
#
################################################################################

# CMake<->Cargo integration. slint-cpp's CMake does
# find_package(Corrosion QUIET 0.6) and falls back to a GitHub FetchContent
# clone at configure time; installing it here keeps configure off the
# network. Nothing Rust is compiled (cmake >= 3.19 skips the legacy
# generator tool), but corrosion's own configure runs FindRust, so cargo
# and rustc must already be in HOST_DIR.
HOST_CORROSION_VERSION = 0.6.1
HOST_CORROSION_SITE = $(call github,corrosion-rs,corrosion,v$(HOST_CORROSION_VERSION))
HOST_CORROSION_LICENSE = MIT
HOST_CORROSION_LICENSE_FILES = LICENSE
HOST_CORROSION_DEPENDENCIES = host-rustc
# Pin libdir: GNUInstallDirs would pick lib64 on some hosts and slint-cpp's
# -DCorrosion_DIR points into lib/ -- a miss would silently fall back to a
# network FetchContent of corrosion.
HOST_CORROSION_CONF_OPTS = \
	-DCORROSION_BUILD_TESTS=OFF \
	-DCMAKE_INSTALL_LIBDIR=lib

$(eval $(host-cmake-package))
