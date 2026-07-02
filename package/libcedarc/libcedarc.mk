################################################################################
#
# libcedarc
#
################################################################################
LIBCEDARC_VERSION = master
LIBCEDARC_SITE = $(call github,aodzip,libcedarc,$(LIBCEDARC_VERSION))
LIBCEDARC_DEPENDENCIES = 
LIBCEDARC_INSTALL_STAGING = YES
LIBCEDARC_INSTALL_TARGET = YES
LIBCEDARC_AUTORECONF = YES
LIBCEDARC_ARCHLIB = $(call qstrip,$(BR2_PACKAGE_LIBCEDARC_ARCHLIB))
LIBCEDARC_CONF_ENV = \
	CFLAGS="$(TARGET_CFLAGS)" \
	LDFLAGS="$(TARGET_LDFLAGS) -L$(@D)/library/$(LIBCEDARC_ARCHLIB)"

define LIBCEDARC_FIXUPS
	# libcedarc hardcodes -Werror in CFLAGS_CDCG (Makefile.inc); this old vendor
	# code trips GCC 15 (use-after-free, etc.). Strip it before autoreconf.
	$(Q)find $(@D) \( -name 'Makefile.inc' -o -name 'Makefile.in' \
		-o -name 'Makefile.am' \) -exec sed -i 's/-Werror//g' {} +
	# F1C200S / ARMv5: the kernel ion cache-flush (dmac_flush_range on user
	# addresses) clobbers VE-written frames with dirty-zero cache lines -> the
	# CPU reads zeros (green). Allocate ion buffers UNCACHED (write-combine) so
	# CPU access is always coherent and no flush is needed.
	$(Q)sed -i 's/AW_ION_CACHED_FLAG | AW_ION_CACHED_NEEDS_SYNC_FLAG/0/g' \
		$(@D)/memory/ionMemory/ionAlloc.c
	# Export ion_alloc_get_dmabuf_fd() so apps can zero-copy frames to DRM.
	$(Q)cat $(BR2_EXTERNAL_CARPLAY_PATH)/package/libcedarc/ion_export.c.inc \
		>> $(@D)/memory/ionMemory/ionAlloc.c
endef
LIBCEDARC_POST_PATCH_HOOKS += LIBCEDARC_FIXUPS
LIBCEDARC_CONF_OPTS = 

LIBCEDARC_INSTALL_STAGING_CMDS = $(TARGET_MAKE_ENV) $(MAKE) DESTDIR=$(STAGING_DIR) -C $(@D) install;

LIBCEDARC_INSTALL_STAGING_CMDS += cp $(@D)/include/* '$(STAGING_DIR)/usr/include/';

# Stage the pre-built VE blobs too, so other packages (e.g. cedar-decode-test)
# can link against -lVE / -lvideoengine.
LIBCEDARC_INSTALL_STAGING_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libVE.so' '$(STAGING_DIR)/usr/lib/';
LIBCEDARC_INSTALL_STAGING_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libvideoengine.so' '$(STAGING_DIR)/usr/lib/';

ifeq ($(BR2_PACKAGE_LIBCEDARC_OPENMAX),y)
LIBCEDARC_INSTALL_STAGING_CMDS += cp $(@D)/openmax/include/* '$(STAGING_DIR)/usr/include/';
endif

LIBCEDARC_INSTALL_TARGET_CMDS = $(TARGET_MAKE_ENV) $(MAKE) DESTDIR=$(TARGET_DIR) -C $(@D) install;
LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libVE.so' '$(TARGET_DIR)/usr/lib/';
LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libvideoengine.so' '$(TARGET_DIR)/usr/lib/';

ifeq ($(BR2_PACKAGE_LIBCEDARC_DECODER_AVS),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawavs.so' '$(TARGET_DIR)/usr/lib/';
endif

ifeq ($(BR2_PACKAGE_LIBCEDARC_DECODER_H264),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawh264.so' '$(TARGET_DIR)/usr/lib/';
endif

ifeq ($(BR2_PACKAGE_LIBCEDARC_DECODER_H265),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawh265.so' '$(TARGET_DIR)/usr/lib/';
endif

ifeq ($(BR2_PACKAGE_LIBCEDARC_DECODER_MJPEG),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawmjpeg.so' '$(TARGET_DIR)/usr/lib/';
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawmjpegplus.so' '$(TARGET_DIR)/usr/lib/';
endif

ifeq ($(BR2_PACKAGE_LIBCEDARC_DECODER_MPEG2),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawmpeg2.so' '$(TARGET_DIR)/usr/lib/';
endif

ifeq ($(BR2_PACKAGE_LIBCEDARC_DECODER_MPEG4),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawmpeg4base.so' '$(TARGET_DIR)/usr/lib/';
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawmpeg4dx.so' '$(TARGET_DIR)/usr/lib/';
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawmpeg4h263.so' '$(TARGET_DIR)/usr/lib/';
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawmpeg4normal.so' '$(TARGET_DIR)/usr/lib/';
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawmpeg4vp6.so' '$(TARGET_DIR)/usr/lib/';
endif

ifeq ($(BR2_PACKAGE_LIBCEDARC_DECODER_VP8),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawvp8.so' '$(TARGET_DIR)/usr/lib/';
endif

ifeq ($(BR2_PACKAGE_LIBCEDARC_DECODER_VP9),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawvp9Hw.so' '$(TARGET_DIR)/usr/lib/';
endif

ifeq ($(BR2_PACKAGE_LIBCEDARC_DECODER_WMV3),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libawwmv3.so' '$(TARGET_DIR)/usr/lib/';
endif

ifeq ($(BR2_PACKAGE_LIBCEDARC_ENCODER),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += cp '$(@D)/library/$(LIBCEDARC_ARCHLIB)/libvencoder.so' '$(TARGET_DIR)/usr/lib/';
endif

ifneq ($(BR2_PACKAGE_LIBCEDARC_OPENMAX),y)
	LIBCEDARC_INSTALL_TARGET_CMDS += rm '$(TARGET_DIR)/usr/lib/libOmxCore.so';
	LIBCEDARC_INSTALL_TARGET_CMDS += rm '$(TARGET_DIR)/usr/lib/libOmxVdec.so';
	LIBCEDARC_INSTALL_TARGET_CMDS += rm '$(TARGET_DIR)/usr/lib/libOmxVenc.so';
endif

$(eval $(autotools-package))
