################################################################################
#
# musb-collision-test
#
################################################################################

MUSB_COLLISION_TEST_VERSION = 1.0
MUSB_COLLISION_TEST_SITE = $(BR2_EXTERNAL_CARPLAY_PATH)/package/musb-collision-test/src
MUSB_COLLISION_TEST_SITE_METHOD = local
MUSB_COLLISION_TEST_LICENSE = GPL-2.0
MUSB_COLLISION_TEST_DEPENDENCIES = libusb

define MUSB_COLLISION_TEST_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -I$(STAGING_DIR)/usr/include/libusb-1.0 \
		$(@D)/musb_collision_test.c -o $(@D)/musb-collision-test \
		$(TARGET_LDFLAGS) -lusb-1.0 -lpthread
endef

define MUSB_COLLISION_TEST_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/musb-collision-test \
		$(TARGET_DIR)/usr/bin/musb-collision-test
endef

$(eval $(generic-package))
