include $(sort $(wildcard $(BR2_EXTERNAL_CARPLAY_PATH)/package/*/*.mk))


# SD card only: the games, Freedoom and the SDL 1.2 stack only they use stay
# out of the NAND image. Every rootfs is packed from its own copy of the target
# dir (TARGET_DIR is that copy inside the filesystem rules), so deleting their
# files in the squashfs pre-gen hook leaves rootfs.ext2 -- the SD card -- intact.
# packages-file-list.txt records which package installed each target file.
CARPLAY_SD_ONLY_PACKAGES = sdl sdl_mixer sdl_net prboom freedoom opentyrian opentyrian-data lbreakout2 ltris game-launcher
define CARPLAY_SQUASHFS_DROP_SD_ONLY
	sed -n -E 's/^($(subst $(space),|,$(strip $(CARPLAY_SD_ONLY_PACKAGES)))),//p' $(BUILD_DIR)/packages-file-list.txt | while read -r f; do rm -f "$(TARGET_DIR)/$$f"; done
	rm -rf $(TARGET_DIR)/usr/share/games
endef
ROOTFS_SQUASHFS_PRE_GEN_HOOKS += CARPLAY_SQUASHFS_DROP_SD_ONLY

# lbreakout2: its configure.in clears the audio and network flags whenever
# --enable-audio / --enable-network is given AT ALL (the AC_ARG_ENABLE action
# ignores the value), so Buildroot's --enable-audio=yes --enable-network=yes
# builds it WITHOUT sound or network ("Compiled without sound and music").
# Both default to on: drop the =yes options. (Upstream Buildroot bug.)
LBREAKOUT2_CONF_OPTS := $(filter-out --enable-audio=yes --enable-network=yes,$(LBREAKOUT2_CONF_OPTS))
