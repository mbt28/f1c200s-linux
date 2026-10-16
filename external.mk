include $(sort $(wildcard $(BR2_EXTERNAL_CARPLAY_PATH)/package/*/*.mk))


# opusfile: Buildroot already builds it against the fixed-point libopus on
# this soft-float target (--enable-fixed-point); also drop its floating-point
# API (op_read_float*, --disable-float) so nothing in the library touches
# software float. CONF_OPTS is expanded when the configure step runs, so
# appending here (after the package was defined) takes effect.
ifeq ($(BR2_PACKAGE_OPUS_FIXED_POINT),y)
OPUSFILE_CONF_OPTS += --disable-float
endif

# SD card only: the games, Freedoom and the SDL 1.2 stack only they use stay
# out of the NAND image. Every rootfs is packed from its own copy of the target
# dir (TARGET_DIR is that copy inside the filesystem rules), so deleting their
# files in the squashfs pre-gen hook leaves rootfs.ext2 -- the SD card -- intact.
# packages-file-list.txt records which package installed each target file.
CARPLAY_SD_ONLY_PACKAGES = sdl sdl_mixer sdl_net prboom freedoom opentyrian opentyrian-data lbreakout2 ltris
define CARPLAY_SQUASHFS_DROP_SD_ONLY
	sed -n -E 's/^($(subst $(space),|,$(strip $(CARPLAY_SD_ONLY_PACKAGES)))),//p' $(BUILD_DIR)/packages-file-list.txt | while read -r f; do rm -f "$(TARGET_DIR)/$$f"; done
	rm -rf $(TARGET_DIR)/usr/share/games
endef
ROOTFS_SQUASHFS_PRE_GEN_HOOKS += CARPLAY_SQUASHFS_DROP_SD_ONLY
