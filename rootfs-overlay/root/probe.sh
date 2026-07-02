#!/bin/sh
# Decode the test clip (no display) and print the cedrus luma/chroma probe.
pkill -f fastcarplay 2>/dev/null
pkill -f cedrus_drm_test 2>/dev/null
dmesg -c >/dev/null 2>&1
ffmpeg -hwaccel drm -i /root/videos/test.h264 -frames:v 400 -f null - >/dev/null 2>&1
echo "----- CEDRUS_PROBE -----"
dmesg | grep CEDRUS_PROBE || echo "(no probe output)"
