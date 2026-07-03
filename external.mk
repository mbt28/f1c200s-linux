include $(sort $(wildcard $(BR2_EXTERNAL_CARPLAY_PATH)/package/*/*.mk))

# gcc 14.3's libsanitizer unconditionally includes <linux/scc.h>, which the
# kernel removed; with the toolchain on CUSTOM_7_0 headers (the 7.1.x move)
# host-gcc-final dies with "linux/scc.h: No such file or directory". Nothing
# on this ARMv5 appliance uses sanitizers -- drop the target lib entirely.
# (external.mk is included after Buildroot's package/*.mk, so this append
# reaches the gcc configure; same pattern Buildroot itself uses for
# musl/sparc/thumb1.)
HOST_GCC_COMMON_CONF_OPTS += --disable-libsanitizer

# >>> CEDAR INTEGRATION (peteallenm VE + ION) >>>
# Inject the Allwinner Cedar VideoEngine + ION driver into the kernel staging
# tree before the kernel is configured, so its Kconfig symbols become
# selectable and the config fragment can turn them on. Runs as a kernel
# POST_PATCH hook so it survives `make linux-dirclean` / clean rebuilds.
#
# Kept in-tree as the correct-colour FALLBACK while the cedrus green-chroma bug
# is open (the cedrus-only image does not select it; flip the defconfig back to
# CEDAR_VE/ION + libcedarc to use it). This lives in external.mk (not local.mk)
# because Buildroot only auto-includes local.mk from $(CONFIG_DIR) (the output
# dir), whereas external.mk is always included for a BR2_EXTERNAL tree. Source is
# editable at CEDAR_SRC_DIR (re-copied every build) so fixing 6.1->6.6 compile
# issues is just editing it.
#
# Source is the user's cedar repo, fetched into cedar/src by
# scripts/fetch-sources.sh (see cedar/README.md). Override for local hacking:
#   make CEDAR_SRC_DIR=/path/to/cedar ...
CEDAR_SRC_DIR ?= $(BR2_EXTERNAL_CARPLAY_PATH)/cedar/src

define CEDAR_INTEGRATE
	@echo ">>> [cedar] injecting VE+ION driver into $(LINUX_DIR)"
	$(Q)rm -rf $(LINUX_DIR)/drivers/staging/media/sunxi/cedar
	$(Q)mkdir -p $(LINUX_DIR)/drivers/staging/media/sunxi/cedar
	$(Q)cp -a $(CEDAR_SRC_DIR)/. $(LINUX_DIR)/drivers/staging/media/sunxi/cedar/
	$(Q)if ! grep -q 'cedar/Kconfig' $(LINUX_DIR)/drivers/staging/media/sunxi/Kconfig; then \
		sed -i '/cedrus\/Kconfig/a source "drivers/staging/media/sunxi/cedar/Kconfig"' \
			$(LINUX_DIR)/drivers/staging/media/sunxi/Kconfig; \
		echo ">>> [cedar] Kconfig hooked"; \
	fi
	$(Q)if ! grep -q 'cedar/' $(LINUX_DIR)/drivers/staging/media/sunxi/Makefile; then \
		echo 'obj-y += cedar/' >> $(LINUX_DIR)/drivers/staging/media/sunxi/Makefile; \
		echo ">>> [cedar] Makefile hooked"; \
	fi
endef
LINUX_POST_PATCH_HOOKS += CEDAR_INTEGRATE
# <<< CEDAR INTEGRATION <<<
