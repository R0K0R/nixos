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


def width_of(address):
    for c in hypr("clients"):
        if c.get("address") == address:
            return c["size"][0]
    return None


def focus(address):
    subprocess.run(
        ["hyprctl", "eval", 'hl.dispatch(hl.dsp.focus({ window = "address:%s" }))' % address],
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

    # Keep both columns usable: clamp so neither drops below 10% of the monitor.
    min_w = round(mon_w * 0.1)
    total = focused_w + neighbour_w
    f_win = active
    n_win = neighbour[0]

    # Move the seam without leaving a gap. Two facts about the scrolling layout
    # drive the order:
    #   - Shrinking a column always lands exactly (no clamp).
    #   - Growing only lands cleanly on the FOCUSED column with ROOM to grow:
    #     it centres/keeps the focused column visible and lets the far side
    #     overflow. Growing a non-focused column, or growing into no free space,
    #     hits centre-and-fit and clamps short -- the total drops and a gap
    #     appears (what looked like "both shrink").
    # So: shrink the shrinking side first to free the room, then focus the
    # growing side and grow it into that room, then restore focus. A read-back
    # gives any shortfall back to the shrunk side so the pair always sums to the
    # original total.
    if delta > 0:
        grow, shrink = f_win, n_win  # focused grows, neighbour shrinks
    else:
        grow, shrink = n_win, f_win  # focused shrinks, neighbour grows
    grow_w = grow["size"][0]
    shrink_w = shrink["size"][0]
    grow_target = max(min_w, min(grow_w + abs(delta), total - min_w))
    shrink_target = total - grow_target

    resize_exact(shrink["address"], shrink_target, shrink["size"][1])  # free room
    hopped = grow["address"] != active["address"]
    if hopped:
        focus(grow["address"])
    resize_exact(grow["address"], grow_target, grow["size"][1])
    actual = width_of(grow["address"]) or grow_target
    if actual != grow_target:
        resize_exact(shrink["address"], max(min_w, total - actual), shrink["size"][1])
    if hopped:
        focus(active["address"])


if __name__ == "__main__":
    main()
