#!/usr/bin/env python3
"""Render the braille bonfire mark (logo.txt) to a fire-gradient PNG for the Plymouth boot splash.
Same gradient stops as features/fastfetch/fire.py, so the boot logo matches the terminal one.
Usage: plymouth-logo.py <logo.txt> <font.ttf> <out.png>"""
import sys
from PIL import Image, ImageDraw, ImageFont

logo_path, font_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(logo_path, encoding="utf-8").read().rstrip("\n").split("\n")

SIZE = 44
font = ImageFont.truetype(font_path, SIZE)
cw = font.getlength("⣿")                 # monospace cell advance (full braille cell)
asc, desc = font.getmetrics()
lh = asc + desc
pad = 4
W = int(cw * max(len(line) for line in lines)) + pad * 2
H = lh * len(lines) + pad * 2

STOPS = [(0.0, (255, 224, 120)), (0.45, (255, 140, 40)), (0.75, (240, 70, 24)), (1.0, (170, 28, 12))]


def grad(t):
    for i in range(len(STOPS) - 1):
        t0, c0 = STOPS[i]
        t1, c1 = STOPS[i + 1]
        if t <= t1:
            f = (t - t0) / (t1 - t0) if t1 > t0 else 0
            return tuple(int(c0[j] + (c1[j] - c0[j]) * f) for j in range(3))
    return STOPS[-1][1]


img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)
n = len(lines)
for i, line in enumerate(lines):
    t = i / (n - 1) if n > 1 else 0.0
    draw.text((pad, pad + i * lh), line, font=font, fill=grad(t) + (255,))
img.save(out_path)
