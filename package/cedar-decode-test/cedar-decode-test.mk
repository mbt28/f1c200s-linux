################################################################################
#
# cedar-decode-test
#
################################################################################

CEDAR_DECODE_TEST_VERSION = 1.0
CEDAR_DECODE_TEST_SITE = $(BR2_EXTERNAL_CARPLAY_PATH)/package/cedar-decode-test/src
CEDAR_DECODE_TEST_SITE_METHOD = local
CEDAR_DECODE_TEST_LICENSE = GPL-2.0
CEDAR_DECODE_TEST_DEPENDENCIES = libcedarc libdrm

define CEDAR_DECODE_TEST_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -I$(STAGING_DIR)/usr/include \
		-I$(STAGING_DIR)/usr/include/libdrm \
		$(@D)/cedar_decode_test.c -o $(@D)/cedar-decode-test \
		$(TARGET_LDFLAGS) \
		-lvdecoder -lcdc_base -lMemAdapter -lVE -lvideoengine \
		-ldrm -ldl -lrt -lpthread
endef

define CEDAR_DECODE_TEST_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/cedar-decode-test \
		$(TARGET_DIR)/usr/bin/cedar-decode-test
endef

$(eval $(generic-package))
