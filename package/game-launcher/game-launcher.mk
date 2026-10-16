################################################################################
#
# game-launcher
#
################################################################################

GAME_LAUNCHER_VERSION = 1.0
GAME_LAUNCHER_SITE = $(BR2_EXTERNAL_CARPLAY_PATH)/package/game-launcher/src
GAME_LAUNCHER_SITE_METHOD = local
GAME_LAUNCHER_LICENSE = GPL-2.0

define GAME_LAUNCHER_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(@D)/vtreset.c \
		-o $(@D)/vtreset $(TARGET_LDFLAGS)
endef

define GAME_LAUNCHER_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/vtreset $(TARGET_DIR)/usr/sbin/vtreset
	$(INSTALL) -D -m 0755 $(@D)/game $(TARGET_DIR)/usr/bin/game
endef

$(eval $(generic-package))
