################################################################################
#
# cp-mux-probe
#
################################################################################

CP_MUX_PROBE_VERSION = 1.0
CP_MUX_PROBE_SITE = $(BR2_EXTERNAL_CARPLAY_PATH)/package/cp-mux-probe/src
CP_MUX_PROBE_SITE_METHOD = local
CP_MUX_PROBE_LICENSE = GPL-2.0

# Talks to usbfs directly, so it needs nothing but libc -- which is what lets it
# be cross-built by hand and dropped onto a board over serial when a full image
# rebuild is not worth the turnaround.
define CP_MUX_PROBE_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(@D)/cp_mux_probe.c \
		-o $(@D)/cp-mux-probe $(TARGET_LDFLAGS)
endef

define CP_MUX_PROBE_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/cp-mux-probe \
		$(TARGET_DIR)/usr/bin/cp-mux-probe
endef

$(eval $(generic-package))
