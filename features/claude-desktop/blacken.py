#!/usr/bin/env python3
"""Force Claude Desktop's dark-theme base backgrounds to pure black.

Why: the Hyprland glass look (opacity 0.65 + blur) composites
screen = 0.65*bg + 0.35*backdrop, so kitty/dolphin sit on #000 and any
nonzero app background is a constant haze no opacity value can cancel
(0.92 was tried: brightness parity, but the glass texture dies).

How: the theme lives in three places -- window-shared.css + inline CSS in
the renderer HTMLs inside app.asar (`.darkTheme`, claude.ai v1 palette),
and the chat SPA's hashed CSS in resources/ion-dist (v1 + a v2
--_gray-ramp indirection). All patches are SAME-LENGTH byte replacements
(hsl lightness "18.4%" -> "00.0%", var() refs -> space-padded literals),
which keeps every asar offset valid. app.asar's per-file SHA256 integrity
records (the integrity fuse is enabled) are then recomputed and patched
into the header, which also stays the same size because hex digests have
fixed length. Backgrounds are zeroed through bg-300 (bg-200 alone still
read visibly lighter than kitty side-by-side); bg-400/500 keep their
stock values so popovers/menus retain some separation.

Usage: blacken.py <resources-dir>   (the dir holding app.asar + ion-dist)
"""

import hashlib
import json
import struct
import sys
from pathlib import Path

REPLACEMENTS = [
    # claude.ai v1 palette, dark: --bg-000 / --bg-100 (asar .darkTheme
    # blocks and ion-dist alike; bare literals are safe -- they only occur
    # as these properties)
    (b"60 2.1% 18.4%", b"60 2.1% 00.0%"),
    (b"60 2.7% 14.5%", b"60 2.7% 00.0%"),
    # v1 dark --bg-200/300: MUST be property-scoped -- the bare colors
    # double as light-theme --border-*/--text-* values. Minified (ion-dist)
    # and space-after-colon (asar window-shared.css) forms.
    (b"--bg-200:30 3.3% 11.8%", b"--bg-200:30 3.3% 00.0%"),
    (b"--bg-200: 30 3.3% 11.8%", b"--bg-200: 30 3.3% 00.0%"),
    (b"--bg-300:60 2.6% 7.6%", b"--bg-300:60 2.6% 0.0%"),
    (b"--bg-300: 60 2.6% 7.6%", b"--bg-300: 60 2.6% 0.0%"),
    # v2 palette (ion-dist): remap the semantic var, not the gray ramp --
    # --_gray-750/800 also feed --pictogram-300/400
    (b"--bg-000:var(--_gray-750)", b"--bg-000:0 0% 0%         "),
    (b"--bg-100:var(--_gray-800)", b"--bg-100:0 0% 0%         "),
    (b"--bg-200:var(--_gray-840)", b"--bg-200:0 0% 0%         "),
    (b"--bg-300:var(--_gray-860)", b"--bg-300:0 0% 0%         "),
    # flat achromatic dark ramp (Code tab / alternate palette in ion-dist)
    (b"--bg-000:0 0% 6%", b"--bg-000:0 0% 0%"),
    (b"--bg-100:0 0% 10%", b"--bg-100:0 0% 00%"),
    (b"--bg-200:0 0% 14%", b"--bg-200:0 0% 00%"),
    (b"--bg-300:0 0% 17%", b"--bg-300:0 0% 00%"),
    # desktop-frame (--df-*) z-layer system, dark ramp: the window shell,
    # sidebar and tab chrome paint from these, NOT from --bg-*. The z2
    # residual (14.9% * 0.65 ~= +25 brightness) was exactly the measured
    # gap vs kitty at the window boundary. z4+ (23.9%+) kept for overlays.
    (b"--df-z0: 0 0% 3.9%", b"--df-z0: 0 0% 0.0%"),
    (b"--df-z1: 0 0% 10.2%", b"--df-z1: 0 0% 00.0%"),
    (b"--df-z2: 0 0% 14.9%", b"--df-z2: 0 0% 00.0%"),
    (b"--df-z3: 0 0% 20%", b"--df-z3: 0 0% 00%"),
    (b"--df-z0:0 0% 3.9%", b"--df-z0:0 0% 0.0%"),
    (b"--df-z1:0 0% 10.2%", b"--df-z1:0 0% 00.0%"),
    (b"--df-z2:0 0% 14.9%", b"--df-z2:0 0% 00.0%"),
    (b"--df-z3:0 0% 20%", b"--df-z3:0 0% 00%"),
    # window frame base color (every renderer html + window-shared.css in
    # the asar): this is what shows as the window's own canvas under the
    # SPA, and it's what a blank frame paints. #262624 is claude.ai's dark
    # carbon; the light twin #faf9f5 stays.
    (
        b"--claude-background-color: #262624",
        b"--claude-background-color: #000000",
    ),
    # Electron BrowserWindow.backgroundColor (main-process JS): the native
    # window fill shows through the client-side-decoration caption strip
    # behind the min/max/close buttons -- the web title bar there is a
    # transparent draggable div, so nothing else paints it. zh() returns
    # #1f1f1e in dark mode; black it (light branch #fdfdfc kept). Single
    # occurrence, same length -> safe byte patch.
    (b'?"#1f1f1e":"#fdfdfc"', b'?"#000000":"#fdfdfc"'),
    # direct sidebar declarations bypassing the z ramp
    (b"hsla(0, 0%, 7.8%, .9)", b"hsla(0, 0%, 0.0%, .9)"),
    (
        b"--df-sidebar-bg: hsl(var(--_gray-860) / .95)",
        b"--df-sidebar-bg: hsl(0 0% 0% / .95)         ",
    ),
    (
        b"--df-sidebar-bg:hsl(var(--_gray-860) / .95)",
        b"--df-sidebar-bg:hsl(0 0% 0% / .95)         ",
    ),
]

for old, new in REPLACEMENTS:
    assert len(old) == len(new), (old, new)


def patch_bytes(data: bytes) -> tuple[bytes, int]:
    n = 0
    for old, new in REPLACEMENTS:
        n += data.count(old)
        data = data.replace(old, new)
    return data, n


# The main-window UI is NOT the bundled ion-dist: the content view loads
# the live SPA from claude.ai at runtime (ion-dist is only a dead fallback
# -- blocking the host blanks the app instead of falling back), so the CSS
# repaints above never reach the sidebar and panels of the live UI. The
# one thing we own that runs inside those remote documents is their Electron
# preload script: contextIsolation isolates the JS world but the preload
# still shares the page DOM, so it can install !important overrides for the
# background custom properties that beat any (remote) stylesheet, now and
# after upstream style updates. mainView.js is the claude.ai content view's
# preload; mainWindow.js the shell/title-bar; claudePagePreview.js the
# in-app browser -- patch all three. (index.pre.js is Sentry, not a
# preload -- do not target it.) Gated on dark mode so light theme stays
# stock. adoptedStyleSheets first (immune to page CSP style-src), <style>
# fallback, MutationObserver-free re-assert on each doc.
PRELOAD_JS = (
    b'\n;(()=>{try{'
    b'if(!matchMedia("(prefers-color-scheme: dark)").matches)return;'
    # Scope, from a live DOM probe (getComputedStyle at each region):
    #   backdrop  = <body class=bg-bg-100>        -> var(--bg-100)
    #   chat box  = <div class=bg-bg-000>         -> var(--bg-000)
    #   main pane = <main class=dframe-content>   -> hardcoded rgb(31,31,30)
    #   sidebar   = <aside class=dframe-sidebar>  -> rgb(38,38,38)
    #   title bar = shell (mainWindow) chrome     -> var(--claude-background-color)
    # backdrop/chat box -> #000. Main pane and title-bar strip are painted by
    # a hardcoded color / --claude-background-color respectively, so they need
    # their own overrides. Sidebar is dropped to near-black (0 0% 6%) rather
    # than pure #000 -- a faint separation from the main pane, matching the
    # DankMatugenBlack 13,13,13 alternate-surface philosophy.
    b'const css=":root,:root *{'
    b'--bg-000:0 0% 0%!important;--bg-100:0 0% 0%!important;'
    b'--claude-background-color:#000!important}'
    b'.dframe-content{background-color:#000!important}'
    b'.dframe-sidebar{background-color:hsl(0 0% 6%)!important}";'
    b'const a=()=>{try{const s=new CSSStyleSheet();s.replaceSync(css);'
    b'document.adoptedStyleSheets=[...document.adoptedStyleSheets,s]}'
    b'catch(e){const t=document.createElement("style");t.textContent=css;'
    b'document.documentElement.appendChild(t)}};'
    b'document.readyState==="loading"'
    b'?document.addEventListener("DOMContentLoaded",a):a()'
    b'}catch(e){}})();\n'
)
PRELOAD_PATHS = (
    "/.vite/build/mainView.js",
    "/.vite/build/mainWindow.js",
    "/.vite/build/claudePagePreview.js",
)


def rebuild_asar(asar: Path) -> tuple[int, bool]:
    """Patch file contents, append PRELOAD_JS to the preload bundle, and
    rewrite the archive with recomputed offsets and integrity records. A
    full rebuild is needed because the injection changes a file's size;
    Linux Electron does not bind the header to the binary (verified: the
    earlier in-place header hash rewrites ran fine)."""
    raw = asar.read_bytes()

    def u32(off):
        return struct.unpack_from("<I", raw, off)[0]

    # File data begins right after the header pickle: 8 (size pickle) + its
    # payload word1. json_len (word3) may be unpadded, so derive the JSON
    # slice from word3 but the data base from word1 (padding-safe).
    data_base = 8 + u32(4)
    json_len = u32(12)
    header = json.loads(raw[16 : 16 + json_len].decode())

    entries = []

    def walk(node, path=""):
        for name, ent in node.get("files", {}).items():
            sub = f"{path}/{name}"
            if "files" in ent:
                walk(ent, sub)
            elif "offset" in ent:
                entries.append((sub, ent))

    walk(header)
    entries.sort(key=lambda e: int(e[1]["offset"]))

    patched = 0
    injected = set()
    blobs = []
    for sub, ent in entries:
        off = data_base + int(ent["offset"])
        data = raw[off : off + ent["size"]]
        data, n = patch_bytes(data)
        patched += n
        if sub in PRELOAD_PATHS:
            data += PRELOAD_JS
            injected.add(sub)
        blobs.append((ent, data))

    pos = 0
    for ent, data in blobs:
        ent["offset"] = str(pos)
        ent["size"] = len(data)
        pos += len(data)
        integ = ent.get("integrity")
        if integ:
            assert integ["algorithm"] == "SHA256"
            block = integ["blockSize"]
            integ["hash"] = hashlib.sha256(data).hexdigest()
            integ["blocks"] = [
                hashlib.sha256(data[i : i + block]).hexdigest()
                for i in range(0, len(data), block)
            ]

    # chromium-pickle framing (@electron/asar): a size pickle then a header
    # pickle. json_len is the UNPADDED string length (the pickle's
    # ReadString count); the payload is zero-padded to a 4-byte boundary and
    # that padded length feeds the two payload-size words. Getting json_len
    # wrong by the pad bytes makes Electron read the trailing NULs as part
    # of the JSON -> "Failed to parse header". Recompute all four words from
    # scratch rather than deltas off the original (robust to the original's
    # own alignment).
    hjson = json.dumps(header, separators=(",", ":")).encode()
    json_len = len(hjson)
    padded = hjson + b"\x00" * ((4 - json_len % 4) % 4)
    header_payload = 4 + len(padded)  # 4-byte strlen field + padded string
    framing = struct.pack("<IIII", 4, header_payload + 4, header_payload, json_len)
    asar.write_bytes(framing + padded + b"".join(d for _, d in blobs))
    return patched, injected


def main(resources: Path) -> None:
    total = 0

    # Bundled fallback SPA + worker windows still get the CSS repaint.
    for css in (resources / "ion-dist").rglob("*.css"):
        data, n = patch_bytes(css.read_bytes())
        if n:
            css.write_bytes(data)
            total += n

    patched_asar, injected = rebuild_asar(resources / "app.asar")
    total += patched_asar
    print(
        f"blacken: {total} replacements ({patched_asar} inside app.asar), "
        f"preload injected into {sorted(p.rsplit('/', 1)[-1] for p in injected)}"
    )
    if patched_asar == 0:
        sys.exit("blacken: no replacements inside app.asar -- palette changed?")
    missing = set(PRELOAD_PATHS) - injected
    if missing:
        sys.exit(f"blacken: preload(s) not found -- renamed? {sorted(missing)}")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
