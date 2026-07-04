#!/usr/bin/env python3
"""Generate the FastCarPlay psplash themes (480x272, bottom ~40px kept calm
for the progress bar). Pick one by pointing BR2_PACKAGE_PSPLASH_IMAGE at it
and rebuilding psplash (psplash-dirclean). Requires Pillow + the FastCarPlay
font (path via FCP_FONT env or ../../../FastCarPlay/src/resource/font.ttf)."""

import os
import math
import random
from PIL import Image, ImageDraw, ImageFont

W, H = 480, 272
OUT = os.path.dirname(os.path.abspath(__file__))
FONT = os.environ.get("FCP_FONT",
                      os.path.join(OUT, "../../../../FastCarPlay/src/resource/font.ttf"))

WHITE = (232, 238, 244)
GRAY = (127, 147, 166)


def font(sz):
    return ImageFont.truetype(FONT, sz)


def grad(top, bot):
    img = Image.new("RGB", (W, H), top)
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)],
               fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bot)))
    return img, d


def center(d, y, text, f, fill):
    b = d.textbbox((0, 0), text, font=f)
    d.text(((W - (b[2] - b[0])) // 2 - b[0], y), text, font=f, fill=fill)
    return b[3] - b[1]


def save(img, name):
    img.save(os.path.join(OUT, name), optimize=True)
    print("saved", name)


# 01 — play ring + motion lines (the original theme)
def t01():
    img, d = grad((11, 15, 20), (19, 28, 38))
    blue, dim = (33, 176, 254), (23, 92, 130)
    cx, cy, r = 240, 100, 42
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=blue, width=5)
    d.polygon([(cx - 12, cy - 20), (cx - 12, cy + 20), (cx + 22, cy)], fill=blue)
    for lw, yo in ((34, -14), (46, 0), (34, 14)):
        x1 = cx - r - 22 - lw
        d.rounded_rectangle([x1, cy + yo - 3, x1 + lw, cy + yo + 3], radius=3, fill=dim)
    center(d, 160, "FastCarPlay", font(38), WHITE)
    center(d, 206, "powered by free software", font(16), GRAY)
    save(img, "01-play-ring.png")


# 02 — phone <-> car link
def t02():
    img, d = grad((13, 13, 18), (24, 22, 34))
    acc = (167, 139, 250)  # violet
    # phone
    px, py = 130, 62
    d.rounded_rectangle([px, py, px + 52, py + 88], radius=10, outline=acc, width=4)
    d.line([px + 18, py + 74, px + 34, py + 74], fill=acc, width=4)
    d.polygon([(px + 20, py + 30), (px + 20, py + 54), (px + 38, py + 42)], fill=acc)
    # car (simple silhouette)
    cx, cy = 300, 118
    d.rounded_rectangle([cx, cy - 16, cx + 84, cy + 8], radius=8, fill=acc)
    d.polygon([(cx + 14, cy - 34), (cx + 62, cy - 34), (cx + 74, cy - 14),
               (cx + 8, cy - 14)], fill=acc)
    for wx in (cx + 18, cx + 64):
        d.ellipse([wx - 9, cy + 1, wx + 9, cy + 19], fill=(13, 13, 18), outline=acc, width=4)
    # link arrows
    ax = 208
    d.line([ax, 96, ax + 64, 96], fill=WHITE, width=3)
    d.polygon([(ax + 64, 90), (ax + 64, 102), (ax + 76, 96)], fill=WHITE)
    d.line([ax + 12, 116, ax + 76, 116], fill=WHITE, width=3)
    d.polygon([(ax + 12, 110), (ax + 12, 122), (ax, 116)], fill=WHITE)
    center(d, 168, "FastCarPlay", font(34), WHITE)
    center(d, 210, "your phone, on the dash", font(15), GRAY)
    save(img, "02-phone-car-link.png")


# 03 — tux-ish penguin, powered by Linux
def t03():
    img, d = grad((10, 14, 12), (18, 30, 24))
    cx, cy = 240, 96
    black, belly, orange = (24, 26, 30), (236, 238, 240), (247, 166, 42)
    d.ellipse([cx - 34, cy - 44, cx + 34, cy + 52], fill=black)              # body
    d.ellipse([cx - 22, cy - 6, cx + 22, cy + 48], fill=belly)               # belly
    d.ellipse([cx - 24, cy - 44, cx + 24, cy - 2], fill=black)               # head
    d.ellipse([cx - 14, cy - 34, cx - 4, cy - 22], fill=belly)               # eyes
    d.ellipse([cx + 4, cy - 34, cx + 14, cy - 22], fill=belly)
    d.ellipse([cx - 10, cy - 30, cx - 6, cy - 25], fill=black)
    d.ellipse([cx + 6, cy - 30, cx + 10, cy - 25], fill=black)
    d.polygon([(cx - 8, cy - 20), (cx + 8, cy - 20), (cx, cy - 10)], fill=orange)  # beak
    d.ellipse([cx - 40, cy + 40, cx - 12, cy + 54], fill=orange)             # feet
    d.ellipse([cx + 12, cy + 40, cx + 40, cy + 54], fill=orange)
    center(d, 170, "FastCarPlay", font(34), WHITE)
    center(d, 212, "powered by Linux", font(16), (142, 197, 160))
    save(img, "03-tux.png")


# 04 — road to horizon, night
def t04():
    img, d = grad((6, 8, 16), (26, 20, 40))
    random.seed(7)
    for _ in range(70):                                   # stars
        x, y = random.randint(0, W - 1), random.randint(0, 120)
        d.point((x, y), fill=(random.randint(120, 220),) * 3)
    hy = 150                                              # horizon
    d.line([(0, hy), (W, hy)], fill=(60, 50, 90), width=2)
    for off in (-160, -60, 60, 160):                      # road edges + lanes
        d.line([(240 + off // 8, hy), (240 + off, H)], fill=(120, 110, 160), width=3)
    for i in range(5):                                    # dashed center line
        y1 = hy + 12 + i * 24
        d.line([(240, y1), (240, y1 + 12)], fill=(220, 210, 120), width=4)
    d.ellipse([358, 34, 402, 78], fill=(240, 236, 200))   # moon
    d.ellipse([348, 28, 384, 64], fill=(10, 11, 20))
    f = font(34)
    center(d, 58, "FastCarPlay", f, WHITE)
    center(d, 100, "powered by Linux", font(15), GRAY)
    save(img, "04-night-road.png")


# 05 — speedometer
def t05():
    img, d = grad((12, 12, 12), (28, 22, 18))
    amber = (255, 170, 40)
    cx, cy, r = 240, 128, 84
    d.arc([cx - r, cy - r, cx + r, cy + r], start=150, end=390, fill=(90, 70, 50), width=10)
    d.arc([cx - r, cy - r, cx + r, cy + r], start=150, end=330, fill=amber, width=10)
    for a in range(150, 391, 30):                         # ticks
        rad = math.radians(a)
        x1 = cx + (r - 16) * math.cos(rad); y1 = cy + (r - 16) * math.sin(rad)
        x2 = cx + (r - 4) * math.cos(rad);  y2 = cy + (r - 4) * math.sin(rad)
        d.line([(x1, y1), (x2, y2)], fill=(200, 190, 170), width=3)
    rad = math.radians(320)                               # needle
    d.line([(cx, cy), (cx + (r - 24) * math.cos(rad), cy + (r - 24) * math.sin(rad))],
           fill=(240, 80, 60), width=5)
    d.ellipse([cx - 7, cy - 7, cx + 7, cy + 7], fill=WHITE)
    center(d, 34, "FastCarPlay", font(30), WHITE)
    center(d, 196, "powered by free software", font(14), GRAY)
    save(img, "05-speedometer.png")


# 06 — terminal boot
def t06():
    img = Image.new("RGB", (W, H), (8, 10, 8))
    d = ImageDraw.Draw(img)
    green, dgreen = (98, 222, 109), (44, 92, 50)
    d.rounded_rectangle([28, 30, W - 28, 170], radius=8, outline=dgreen, width=2)
    d.rectangle([28, 30, W - 28, 52], fill=(16, 22, 16))
    for i, c in enumerate(((240, 90, 90), (240, 200, 90), (98, 222, 109))):
        d.ellipse([40 + i * 18, 37, 48 + i * 18, 45], fill=c)
    f = font(17)
    d.text((44, 64), "$ modprobe sunxi-cedrus", font=f, fill=dgreen)
    d.text((44, 88), "$ fastcarplay --start", font=f, fill=green)
    d.text((44, 112), "ready.", font=f, fill=dgreen)
    d.rectangle([44 + 60, 136, 44 + 74, 152], fill=green)  # cursor block
    center(d, 186, "FastCarPlay", font(28), WHITE)
    center(d, 222, "powered by free software", font(14), (110, 160, 116))
    save(img, "06-terminal.png")


# 07 — minimal wordmark
def t07():
    img, d = grad((14, 14, 16), (14, 14, 16))
    f1 = font(56)
    b = d.textbbox((0, 0), "FastCarPlay", font=f1)
    x = (W - (b[2] - b[0])) // 2 - b[0]
    d.text((x, 86), "Fast", font=f1, fill=WHITE)
    xb = d.textbbox((x, 86), "Fast", font=f1)
    d.text((xb[2], 86), "Car", font=f1, fill=(33, 176, 254))
    xb2 = d.textbbox((xb[2], 86), "Car", font=f1)
    d.text((xb2[2], 86), "Play", font=f1, fill=WHITE)
    d.rounded_rectangle([x, 160, x + (b[2] - b[0]), 166], radius=3, fill=(33, 176, 254))
    center(d, 186, "powered by free software", font(15), GRAY)
    save(img, "07-wordmark.png")


# 08 — headlights night drive
def t08():
    img, d = grad((6, 6, 10), (16, 14, 22))
    random.seed(3)
    for _ in range(60):
        x, y = random.randint(0, W - 1), random.randint(0, 110)
        d.point((x, y), fill=(random.randint(90, 190),) * 3)
    warm = (255, 214, 120)
    for hx in (170, 310):                                  # beams
        d.polygon([(hx, 208), (hx - 66, H), (hx + 66, H)], fill=(38, 34, 26))
        d.ellipse([hx - 15, 200, hx + 15, 218], fill=warm)
    d.rounded_rectangle([140, 186, 340, 214], radius=14, fill=(30, 30, 40))  # car front
    center(d, 60, "FastCarPlay", font(36), WHITE)
    center(d, 108, "powered by Linux", font(16), GRAY)
    save(img, "08-headlights.png")


# 09 — phone pictogram with radio waves
def t09():
    img, d = grad((10, 16, 18), (16, 30, 34))
    teal = (64, 224, 208)
    px, py = 206, 52
    d.rounded_rectangle([px, py, px + 68, py + 112], radius=12, outline=teal, width=5)
    d.line([px + 24, py + 96, px + 44, py + 96], fill=teal, width=4)
    d.polygon([(px + 24, py + 34), (px + 24, py + 66), (px + 50, py + 50)], fill=teal)
    for i, r in enumerate((26, 42, 58)):                   # waves from the phone
        alpha = 150 - i * 40
        d.arc([px - r, py + 40 - r, px + r, py + 40 + r], start=120, end=240,
              fill=(64, 224, 208, alpha) if img.mode == "RGBA" else
                   tuple(int(c * (1 - i * 0.28)) for c in teal), width=4)
    center(d, 182, "FastCarPlay", font(32), WHITE)
    center(d, 222, "powered by free software", font(14), GRAY)
    save(img, "09-phone-waves.png")


# 10 — sunrise dashboard
def t10():
    img, d = grad((20, 10, 26), (8, 8, 12))
    # sun with banded sky
    for i, r in enumerate(range(78, 18, -12)):
        c = (255, 120 + i * 22, 60 + i * 14)
        d.ellipse([240 - r, 118 - r, 240 + r, 118 + r], fill=c)
    d.rectangle([0, 118, W, H], fill=(10, 9, 14))          # horizon cut
    d.pieslice([60, 120 - 90, 420, 120 + 90], 180, 360, outline=(90, 70, 110), width=4)
    for a in range(200, 341, 35):                          # dash arc ticks
        rad = math.radians(a)
        x1 = 240 + 168 * math.cos(rad); y1 = 120 + 82 * math.sin(rad)
        x2 = 240 + 184 * math.cos(rad); y2 = 120 + 92 * math.sin(rad)
        d.line([(x1, y1), (x2, y2)], fill=(150, 120, 170), width=3)
    center(d, 152, "FastCarPlay", font(34), WHITE)
    center(d, 196, "powered by free software", font(15), (170, 150, 190))
    save(img, "10-sunrise-dash.png")


if __name__ == "__main__":
    for t in (t01, t02, t03, t04, t05, t06, t07, t08, t09, t10):
        t()
