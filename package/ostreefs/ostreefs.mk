################################################################################
#
# The root filesystem as an OSTree system (docs/ostree.md)
#
################################################################################

# A filesystem type, not a post-image script, so that it runs under fakeroot
# in its own copy of the target, with the owners and modes of the users and
# permission tables applied: ostree records them in the commit.
#
# The repository is in the output folder and not in images/: updates are made
# from its history, and "make clean" must not lose it.
ROOTFS_OSTREEFS_DEPENDENCIES = host-e2fsprogs host-ostree

define ROOTFS_OSTREEFS_CMD
	BINARIES_DIR=$(BINARIES_DIR) \
	OSTREE_REPO=$(BASE_DIR)/ostree_repo \
	OSTREE_VERSION=$(BR2_VERSION) \
	OSTREE_FS_KB=$(BR2_TARGET_ROOTFS_OSTREEFS_SIZE) \
	$(BR2_EXTERNAL_CARPLAY_PATH)/board/lctech/pi-f1c200s/ostree-image.sh $(TARGET_DIR) $@
endef

$(eval $(rootfs))
