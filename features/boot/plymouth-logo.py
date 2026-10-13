#!/usr/bin/env python3
"""Render the braille bonfire mark (logo.txt) to a fire-gradient PNG for the Plymouth boot splash.

Decodes each braille cell back into its 2x4 dot grid and draws the dots directly as filled circles --
NO font rendering, so there is no font-with-braille dependency and no .notdef "tofu" risk (DejaVu/
unifont both lack real U+2800 glyphs; the terminal only shows braille via fontconfig fallback, which
PIL has no equivalent of). Same fire gradient as features/fastfetch/fire.py so the splash matches the
terminal mark. Usage: plymouth-logo.py <logo.txt> <out.png>"""
import sys
from PIL import Image, ImageDraw

logo_path, out_path = sys.argv[1], sys.argv[2]
lines = open(logo_path, encoding="utf-8").read().rstrip("\n").split("\n")
rows = len(lines)
cols = max(len(line) for line in lines)

DOT = 11          # px grid pitch per dot
R = 4.3           # dot radius
PAD = 10
GW, GH = cols * 2, rows * 4          # dot-grid dimensions (44 x 48 for the standard mark)
W = GW * DOT + PAD * 2
H = GH * DOT + PAD * 2

# braille bit -> (dx, dy) within the 2x4 cell (inverse of the packing in the logo generator)
BITS = {0x01: (0, 0), 0x02: (0, 1), 0x04: (0, 2), 0x40: (0, 3),
        0x08: (1, 0), 0x10: (1, 1), 0x20: (1, 2), 0x80: (1, 3)}

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
for r, line in enumerate(lines):
    for c, ch in enumerate(line):
        v = ord(ch) - 0x2800
        if v < 0 or v > 0xFF:
            continue
        for bit, (dx, dy) in BITS.items():
            if v & bit:
                gx, gy = c * 2 + dx, r * 4 + dy
                cx = PAD + gx * DOT + DOT / 2
                cy = PAD + gy * DOT + DOT / 2
                col = grad(gy / (GH - 1)) + (255,)
                draw.ellipse([cx - R, cy - R, cx + R, cy + R], fill=col)
img.save(out_path)
