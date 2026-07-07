################################################################################
#
# esp-hosted-ng
#
################################################################################

# Pinned to the commit the release/ng-1.0.6 tag points at -- the ESP32 runs
# the prebuilt firmware from that same release (the transport handshake
# breaks confusingly on driver/firmware version mismatches, so bump both
# together; flashing procedure in docs/wireless-esp-hosted.md).
ESP_HOSTED_NG_VERSION = 8626b42fd3f9eb5a1ccb5daea481f0d8d32b1685
ESP_HOSTED_NG_SITE = $(call github,espressif,esp-hosted,$(ESP_HOSTED_NG_VERSION))
ESP_HOSTED_NG_LICENSE = GPL-2.0
ESP_HOSTED_NG_LICENSE_FILES = esp_hosted_ng/host/LICENSE

# target=spi: build esp32_spi.ko (WiFi + BT both over the SPI link).
# CONFIG_AP_SUPPORT compiles the cfg80211 AP ops in -- SoftAP is the
# wireless-Android-Auto prerequisite (roadmap P5).
ESP_HOSTED_NG_MODULE_SUBDIRS = esp_hosted_ng/host
ESP_HOSTED_NG_MODULE_MAKE_OPTS = target=spi CONFIG_AP_SUPPORT=y

$(eval $(kernel-module))
$(eval $(generic-package))
