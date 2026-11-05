#!/usr/bin/env python3
"""The boot splash: LEHU's badge, centred on black, at the panel's 800x480.

The badge is LEHU's own (lehu/assets/logo/lehu-display.svg, the dot-matrix
display that is also its CarPlay icon). Run from anywhere:

    python3 generate.py /path/to/lehu/assets/logo/lehu-display.svg

It writes lehu.png here: psplash's picture, full screen, on Buildroot
(BR2_PACKAGE_PSPLASH_IMAGE) and on LEHU OS (meta-lehu-os/recipes-core/
psplash/files/psplash-lehu-img.png, a copy). The bar and the messages
under it are psplash's (patches/psplash/). Needs rsvg-convert (librsvg)
and Pillow.
"""
import io
import os
import subprocess
import sys

from PIL import Image

FB_W, FB_H = 800, 480      # EastRising ER-TFT050-6
BADGE_W = 480              # the badge's width on the panel
BACKGROUND = (0, 0, 0)

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: generate.py <lehu-display.svg>")
    png = subprocess.run(["rsvg-convert", "-w", str(BADGE_W), sys.argv[1]],
                         check=True, capture_output=True).stdout
    badge = Image.open(io.BytesIO(png)).convert("RGBA")
    frame = Image.new("RGB", (FB_W, FB_H), BACKGROUND)
    frame.paste(badge, ((FB_W - badge.width) // 2, (FB_H - badge.height) // 2),
                badge)
    frame.save(os.path.join(HERE, "lehu.png"), optimize=True)
    print("lehu.png, %dx%d, badge %dx%d"
          % (FB_W, FB_H, badge.width, badge.height))


if __name__ == "__main__":
    main()
