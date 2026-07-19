################################################################################
#
# esp-hosted-ng
#
################################################################################

# Pinned to esp-hosted master 2026-07-11 (fw NG-1.0.6.0.4) -- picks up the
# post-ng-1.0.6 RX-buffer-size, wifi-retry and PMF fixes chased for the
# WPA2-SoftAP encrypted-data-path failure. The ESP32 runs a CUSTOM firmware
# built from this same commit (v3 bundle, firmware/ in the project dir; the
# transport handshake breaks confusingly on driver/firmware version
# mismatches, so bump both together; flashing in docs/wireless-esp-hosted.md).
ESP_HOSTED_NG_VERSION = 53bdeeece67532cfb11dfa25e82173570bc7cc7b
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
