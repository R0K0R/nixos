#!/usr/bin/env python3
"""Conserved seam resize for Hyprland's scrolling layout.

argv[1] is a signed fraction of the focused monitor's logical width, applied
to the FOCUSED column; its visible neighbour gets the opposite delta, so the
seam between them moves and the total stays constant (a tiling-style divider).

See the comment in features/hyprland/home.nix for why this resizes both
columns by address instead of using `colresize`.
"""
import json
import subprocess
import sys


def hypr(*args):
    return json.loads(subprocess.check_output(["hyprctl", *args, "-j"]))


def resize_exact(address, width, height):
    subprocess.run(
        [
            "hyprctl",
            "eval",
            "hl.dispatch(hl.dsp.window.resize({ x = %d, y = %d, relative = false, "
            'window = "address:%s" }))' % (width, height, address),
        ],
        check=False,
    )


def main():
    try:
        frac = float(sys.argv[1])
    except (IndexError, ValueError):
        return

    active = hypr("activewindow")
    if not active or active.get("floating") or not active.get("address"):
        return

    mon_id = active["monitor"]
    ws_id = active["workspace"]["id"]

    mon = next((m for m in hypr("monitors") if m["id"] == mon_id), None)
    if not mon:
        return
    # Logical width; window widths from hyprctl are already logical too.
    mon_w = mon["width"] / mon["scale"]
    vis_lo = mon["x"]
    vis_hi = mon["x"] + mon_w
    delta = round(frac * mon_w)
    if delta == 0:
        return

    # Tiled, mapped windows sharing this monitor's active workspace.
    wins = [
        c
        for c in hypr("clients")
        if c["mapped"]
        and not c.get("hidden")
        and not c.get("floating")
        and c["monitor"] == mon_id
        and c["workspace"]["id"] == ws_id
        and c["size"][0] > 0
    ]
    if len(wins) < 2:
        return

    # Group windows into columns by x (a column may stack several windows).
    cols = {}
    for c in wins:
        key = round(c["at"][0] / 8) * 8
        cols.setdefault(key, []).append(c)
    ordered = sorted(cols.items(), key=lambda kv: kv[0])

    # Only columns actually on screen can be a seam partner. Resizing against an
    # off-screen column is the "inconsistent" case: the conserved resize lands
    # on a column you cannot see, so on screen only the focused one appears to
    # change and the tape shifts. Keep to what is visible, like the seam drag.
    def on_screen(win_list):
        left = min(w["at"][0] for w in win_list)
        right = max(w["at"][0] + w["size"][0] for w in win_list)
        # Require a real slice on screen, not a 1-2px sliver at the edge: a
        # barely-visible column is effectively off-screen and resizing it at the
        # tape edge misbehaves (it collapsed to 1px in testing).
        overlap = min(right, vis_hi) - max(left, vis_lo)
        return overlap >= 100

    ordered = [kv for kv in ordered if on_screen(kv[1])]
    if len(ordered) < 2:
        return

    fx = round(active["at"][0] / 8) * 8
    idx = next((i for i, (k, _) in enumerate(ordered) if k == fx), None)
    if idx is None:
        return

    # Neighbour: the visible column to the right, else the visible one to the left.
    if idx + 1 < len(ordered):
        neighbour = ordered[idx + 1][1]
    elif idx - 1 >= 0:
        neighbour = ordered[idx - 1][1]
    else:
        return

    focused_w = active["size"][0]
    neighbour_w = neighbour[0]["size"][0]

    # Keep both columns usable: clamp the delta so neither drops below 10% of
    # the monitor (grow is naturally bounded by the neighbour's shrink).
    min_w = round(mon_w * 0.1)
    if delta > 0:
        delta = min(delta, neighbour_w - min_w)
    else:
        delta = -min(-delta, focused_w - min_w)
    if delta == 0:
        return

    # Set EXACT target widths, not relative deltas. Exact widths are idempotent
    # and land precisely (measured); two independent RELATIVE resizes instead
    # drift, because the scrolling layout re-fits after each one so the applied
    # deltas do not compose. The targets sum to the old sum (which already fit),
    # so nothing overflows. Apply the SHRINK side first anyway: growing first
    # would transiently exceed the usable width and trip fit-to-width scaling.
    f_win = active
    n_win = neighbour[0]
    f_new = focused_w + delta
    n_new = neighbour_w - delta
    if delta > 0:
        resize_exact(n_win["address"], n_new, n_win["size"][1])
        resize_exact(f_win["address"], f_new, f_win["size"][1])
    else:
        resize_exact(f_win["address"], f_new, f_win["size"][1])
        resize_exact(n_win["address"], n_new, n_win["size"][1])


if __name__ == "__main__":
    main()
