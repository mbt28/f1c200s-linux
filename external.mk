include $(sort $(wildcard $(BR2_EXTERNAL_CARPLAY_PATH)/package/*/*.mk))


# opusfile: Buildroot already builds it against the fixed-point libopus on
# this soft-float target (--enable-fixed-point); also drop its floating-point
# API (op_read_float*, --disable-float) so nothing in the library touches
# software float. CONF_OPTS is expanded when the configure step runs, so
# appending here (after the package was defined) takes effect.
ifeq ($(BR2_PACKAGE_OPUS_FIXED_POINT),y)
OPUSFILE_CONF_OPTS += --disable-float
endif
