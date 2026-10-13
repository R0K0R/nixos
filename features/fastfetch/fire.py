#!/usr/bin/env python3
"""Colour a braille logo with a vertical fire gradient (24-bit ANSI), top (bright flame) -> bottom
(deep ember). Used at build time to turn the clean logo.txt into fastfetch's `file-raw` logo, so the
canonical logo stays plain braille and only the colours live here."""
import sys

# gradient stops: position 0..1 -> (r, g, b)
STOPS = [
    (0.00, (255, 224, 120)),   # flame tips: warm yellow
    (0.45, (255, 140, 40)),    # body: orange
    (0.75, (240, 70, 24)),     # orange-red
    (1.00, (170, 28, 12)),     # logs/embers: deep red
]


def shade(t):
    for i in range(len(STOPS) - 1):
        (t0, c0), (t1, c1) = STOPS[i], STOPS[i + 1]
        if t <= t1:
            u = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
            return tuple(round(c0[k] + (c1[k] - c0[k]) * u) for k in range(3))
    return STOPS[-1][1]


def main():
    lines = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8")]
    n = max(1, len(lines) - 1)
    out = []
    for i, line in enumerate(lines):
        r, g, b = shade(i / n)
        out.append(f"\x1b[1m\x1b[38;2;{r};{g};{b}m{line}\x1b[0m")
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
