################################################################################
#
# host-corrosion
#
################################################################################

# CMake<->Cargo integration. slint-cpp's CMake does
# find_package(Corrosion QUIET 0.6) and falls back to a GitHub FetchContent
# clone at configure time; installing it here keeps configure off the
# network. Pure CMake with cmake >= 3.19 (the legacy Rust generator tool is
# never built), so no rust dependency.
HOST_CORROSION_VERSION = 0.6.1
HOST_CORROSION_SITE = $(call github,corrosion-rs,corrosion,v$(HOST_CORROSION_VERSION))
HOST_CORROSION_LICENSE = MIT
HOST_CORROSION_LICENSE_FILES = LICENSE
HOST_CORROSION_CONF_OPTS = -DCORROSION_BUILD_TESTS=OFF

$(eval $(host-cmake-package))
