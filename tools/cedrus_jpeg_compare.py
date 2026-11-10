#!/usr/bin/env python3
"""Test tiles for tools/cedrus_jpeg_test.c, and the check of its output.

    cedrus_jpeg_compare.py make DIR      write map-like 256x256 test tiles
    cedrus_jpeg_compare.py check NV12_PREFIX FILE.jpg...

"make" draws synthetic map tiles (roads, parks, water, labels: no real map
data) and saves them as baseline JPEGs: tile0-3 4:2:0 at quality 75-85 as
map tiles come, tile4 4:4:4 (the decoder downsamples it to 4:2:0).

"check" compares NV12_PREFIX<i>.nv12, the hardware decode of the i-th FILE
written by cedrus_jpeg_test -o, with a software decode of FILE (Pillow,
libjpeg's YCbCr output, chroma averaged 2x2 to 4:2:0). It prints the PSNR of
Y, Cb and Cr and fails below 40 dB (Y) or 36 dB (Cb, Cr): IDCTs differ in
rounding, so the two never match bit for bit, but a wrong table, tiling or
plane offset gives far below 30 dB.

Needs Pillow and numpy (on the build host, not the board).
"""
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw

Y_MIN, C_MIN = 40.0, 36.0


def make(folder):
    os.makedirs(folder, exist_ok=True)
    specs = [(75, 2), (80, 2), (85, 2), (80, 2), (85, 0)]
    for n, (quality, sub) in enumerate(specs):
        rnd = random.Random(n)
        im = Image.new("RGB", (256, 256), (242, 239, 233))
        d = ImageDraw.Draw(im)
        for _ in range(4):  # parks and water
            x, y = rnd.randrange(-40, 240), rnd.randrange(-40, 240)
            pts = [(x + rnd.randrange(0, 120), y + rnd.randrange(0, 120))
                   for _ in range(6)]
            d.polygon(pts, fill=rnd.choice([(200, 230, 180), (170, 211, 223)]))
        for _ in range(12):  # buildings
            x, y = rnd.randrange(0, 240), rnd.randrange(0, 240)
            d.rectangle([x, y, x + rnd.randrange(6, 24), y + rnd.randrange(6, 24)],
                        fill=(217, 208, 201), outline=(196, 182, 171))
        for _ in range(7):  # roads
            a = (rnd.randrange(-20, 276), rnd.randrange(-20, 276))
            b = (rnd.randrange(-20, 276), rnd.randrange(-20, 276))
            width = rnd.choice([3, 5, 8, 12])
            d.line([a, b], fill=(160, 160, 160), width=width + 2)
            d.line([a, b], fill=rnd.choice([(255, 255, 255), (247, 250, 191),
                                            (252, 214, 164), (232, 146, 162)]),
                   width=width)
        for _ in range(4):  # labels
            d.text((rnd.randrange(0, 200), rnd.randrange(0, 240)),
                   rnd.choice(["Hauptstrasse", "Park", "Bahnhof", "A 8", "Kirche"]),
                   fill=(60, 60, 60))
        path = os.path.join(folder, "tile%d.jpg" % n)
        im.save(path, "JPEG", quality=quality, subsampling=sub,
                optimize=False, progressive=False)
        print("%s: quality %d, %s, %d bytes" % (
            path, quality, {2: "4:2:0", 0: "4:4:4"}[sub], os.path.getsize(path)))


def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return 99.0 if mse == 0 else 10 * np.log10(255.0 ** 2 / mse)


def check(prefix, files):
    ok = True
    for i, f in enumerate(files):
        im = Image.open(f)
        im.draft("YCbCr", im.size)
        im = im.convert("YCbCr")
        w, h = im.size
        y, cb, cr = (np.asarray(p, dtype=np.float64) for p in im.split())
        sub = lambda c: c.reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3))
        hw = np.fromfile("%s%d.nv12" % (prefix, i), dtype=np.uint8)
        if hw.size != w * h * 3 // 2:
            print("%s: %d bytes of output, %d expected" % (f, hw.size, w * h * 3 // 2))
            ok = False
            continue
        hy = hw[:w * h].reshape(h, w)
        uv = hw[w * h:].reshape(h // 2, w // 2, 2)
        r = (psnr(hy, y), psnr(uv[:, :, 0], sub(cb)), psnr(uv[:, :, 1], sub(cr)))
        good = r[0] >= Y_MIN and r[1] >= C_MIN and r[2] >= C_MIN
        ok &= good
        print("%s: PSNR Y %.1f dB, Cb %.1f dB, Cr %.1f dB  %s" % (
            f, r[0], r[1], r[2], "ok" if good else "FAIL"))
    return ok


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "make":
        make(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "check":
        sys.exit(0 if check(sys.argv[2], sys.argv[3:]) else 1)
    else:
        sys.exit(__doc__)
