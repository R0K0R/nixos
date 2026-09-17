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

# (group, old, new). GROUP is what the build guard counts: a group may hold
# several spellings of the same declaration (minified vs space-after-colon),
# and only needs ONE of them to hit. A group that matches NOTHING fails the
# build -- see main(). That check exists because 1.40609.1 silently moved 13
# of these and the old "did anything at all match?" guard sailed through it.
REPLACEMENTS = [
    # claude.ai v1 palette, dark: --bg-000 / --bg-100 (asar .darkTheme
    # blocks and ion-dist alike; bare literals are safe -- they only occur
    # as these properties)
    ("v1-bg-000", b"60 2.1% 18.4%", b"60 2.1% 00.0%"),
    ("v1-bg-100", b"60 2.7% 14.5%", b"60 2.7% 00.0%"),
    # v1 dark --bg-200/300: MUST be property-scoped -- the bare colors
    # double as light-theme --border-*/--text-* values. Minified (ion-dist)
    # and space-after-colon (asar window-shared.css) forms.
    ("v1-bg-200", b"--bg-200:30 3.3% 11.8%", b"--bg-200:30 3.3% 00.0%"),
    ("v1-bg-200", b"--bg-200: 30 3.3% 11.8%", b"--bg-200: 30 3.3% 00.0%"),
    ("v1-bg-300", b"--bg-300:60 2.6% 7.6%", b"--bg-300:60 2.6% 0.0%"),
    ("v1-bg-300", b"--bg-300: 60 2.6% 7.6%", b"--bg-300: 60 2.6% 0.0%"),
    # v2 palette (ion-dist): remap the semantic var, not the gray ramp --
    # the ramp stops also feed --pictogram-*.
    #
    # RENUMBERED in 1.40609.1: 750/800/840/860 -> 800/850/870/890. The light
    # theme uses --_gray-0/20/40/50 for the same properties, so keying on the
    # dark stop numbers keeps this dark-only.
    ("v2-bg-000", b"--bg-000:var(--_gray-800)", b"--bg-000:0 0% 0%         "),
    ("v2-bg-100", b"--bg-100:var(--_gray-850)", b"--bg-100:0 0% 0%         "),
    ("v2-bg-200", b"--bg-200:var(--_gray-870)", b"--bg-200:0 0% 0%         "),
    ("v2-bg-300", b"--bg-300:var(--_gray-890)", b"--bg-300:0 0% 0%         "),
    # flat achromatic dark ramp (Code tab / alternate palette in ion-dist)
    ("flat-bg-000", b"--bg-000:0 0% 6%", b"--bg-000:0 0% 0%"),
    ("flat-bg-100", b"--bg-100:0 0% 10%", b"--bg-100:0 0% 00%"),
    ("flat-bg-200", b"--bg-200:0 0% 14%", b"--bg-200:0 0% 00%"),
    ("flat-bg-300", b"--bg-300:0 0% 17%", b"--bg-300:0 0% 00%"),
    # desktop-frame (--df-*) z-layer system, dark ramp: the window shell,
    # sidebar and tab chrome paint from these, NOT from --bg-*. The z2
    # residual (14.9% * 0.65 ~= +25 brightness) was exactly the measured
    # gap vs kitty at the window boundary. z4+ (23.9%+) kept for overlays.
    # Values unchanged in 1.40609.1; only the minified spelling now ships.
    ("df-z0", b"--df-z0: 0 0% 3.9%", b"--df-z0: 0 0% 0.0%"),
    ("df-z1", b"--df-z1: 0 0% 10.2%", b"--df-z1: 0 0% 00.0%"),
    ("df-z2", b"--df-z2: 0 0% 14.9%", b"--df-z2: 0 0% 00.0%"),
    ("df-z3", b"--df-z3: 0 0% 20%", b"--df-z3: 0 0% 00%"),
    ("df-z0", b"--df-z0:0 0% 3.9%", b"--df-z0:0 0% 0.0%"),
    ("df-z1", b"--df-z1:0 0% 10.2%", b"--df-z1:0 0% 00.0%"),
    ("df-z2", b"--df-z2:0 0% 14.9%", b"--df-z2:0 0% 00.0%"),
    ("df-z3", b"--df-z3:0 0% 20%", b"--df-z3:0 0% 00%"),
    # NEW in 1.40609.1 -- the "epitaxy" page layer. The main pane paints
    # `background: var(--df-bg-page)`, --df-bg-page is hsl() of this, and
    # --surface-primary and .dframe-content-inner's --bg-100 both derive
    # from it too, so zeroing this one stop blacks all of them. The sidebar
    # follows as well: --df-sidebar-bg became
    # `color-mix(in srgb, hsl(var(--df-bg-page-hsl)) 80%, black)`, which is
    # why the old explicit --df-sidebar-bg patches are gone rather than
    # updated. The light theme's twin is var(--_gray-10) and is untouched.
    ("df-bg-page", b"--df-bg-page-hsl:var(--_gray-850)", b"--df-bg-page-hsl:0 0% 0%         "),
    # window frame base color (every renderer html + window-shared.css in
    # the asar): this is what shows as the window's own canvas under the
    # SPA, and it's what a blank frame paints. #262624 in earlier builds,
    # #151515 since 1.40609.1; the light twin (#faf9f5 -> #fcfcfb) stays.
    # BOTH spellings -- the .html files minify it, window-shared.css does
    # not, and only carrying the spaced form left 20 occurrences grey.
    ("claude-bg-color", b"--claude-background-color: #151515", b"--claude-background-color: #000000"),
    ("claude-bg-color", b"--claude-background-color:#151515", b"--claude-background-color:#000000"),
    # Electron BrowserWindow.backgroundColor (main-process JS): the native
    # window fill shows through the client-side-decoration caption strip
    # behind the min/max/close buttons -- the web title bar there is a
    # transparent draggable div, so nothing else paints it.
    #
    # SHAPE CHANGED in 1.40609.1: was a double-quoted ternary
    # `?"#1f1f1e":"#fdfdfc"`, now an object literal with backticks, read by
    # `function _P(){return nativeTheme.shouldUseDarkColors?fKt.dark:fKt.light}`.
    # Anchored on the whole literal rather than on `dark:` alone so it stays
    # unique, and not on the minified name `fKt`, which moves every build.
    ("electron-window-bg",
     b"{light:`#fcfcfb`,dark:`#151515`}",
     b"{light:`#fcfcfb`,dark:`#000000`}"),
]

for _group, old, new in REPLACEMENTS:
    assert len(old) == len(new), (old, new)


# Length-CHANGING edits, kept apart from REPLACEMENTS because those carry a
# same-length assertion. Nothing requires same length any more -- rebuild_asar
# recomputes every offset, size and integrity record (it must, since it appends
# the preload) -- but the color table keeps the invariant as a cheap safety net,
# so anything that genuinely changes length lives here instead.
RESIZING_EDITS = [
    # Make the MAIN window's surface per-pixel translucent instead of asking
    # the compositor to fade the whole thing.
    #
    # A Hyprland `opacity 0.65` rule multiplies EVERY pixel -- text, images, the
    # PDF thumbnail, and the scroll-fade gradient, whose opaque end stops being
    # opaque so scrolled content bleeds through it and its boundary shows as a
    # hard step. kitty does the opposite and is the look this was chasing all
    # along: background #000000 at background_opacity 0.65, alpha in the SURFACE,
    # content drawn opaque on top. This is that, for Claude.
    #
    # transparent+#00000000 only make the window capable of alpha; what actually
    # paints the glass is the preload's rgba() base below. Both are needed.
    # Anchored on `opacity:+!!i.earlyWindowShow`, which is unique to the main
    # window -- the About and 3P-inference windows also call backgroundColor:_P()
    # and must stay opaque.
    (
        "main-window-transparent",
        b"backgroundColor:_P(),opacity:+!!i.earlyWindowShow",
        b"backgroundColor:`#00000000`,transparent:!0,opacity:+!!i.earlyWindowShow",
    ),
]

GROUP_HITS: dict[str, int] = {g: 0 for g, _o, _n in REPLACEMENTS}
GROUP_HITS.update({g: 0 for g, _o, _n in RESIZING_EDITS})


def patch_bytes(data: bytes) -> tuple[bytes, int]:
    n = 0
    for group, old, new in REPLACEMENTS + RESIZING_EDITS:
        c = data.count(old)
        if c:
            GROUP_HITS[group] += c
            n += c
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
    b"\n;(()=>{try{"
    # Scope, from a live DOM probe plus the 1.40609.1 bundled CSS:
    #   backdrop   <body class=bg-bg-100>       -> var(--bg-100)
    #   chat box   <div class=bg-bg-000>        -> var(--bg-000)
    #   main pane  .dframe-content(-inner)      -> background: var(--df-bg-page)
    #   panels     .epitaxy-root                -> var(--surface-primary)
    #   sidebar    .dframe-sidebar              -> color-mix() off --df-bg-page-hsl
    #   title bar  shell chrome                 -> var(--claude-background-color)
    #
    # --df-bg-page-hsl is the NEW root of the dark page ramp: --df-bg-page,
    # --surface-primary and .dframe-content-inner's --bg-100 all derive from
    # it, so overriding it covers the pane, panels and sidebar at once. The
    # explicit element rules stay as a belt-and-braces layer for anything that
    # hardcodes a background instead of reading the variable.
    # ALPHA lives here, in the surface -- not in a compositor opacity rule.
    # 0.65 black, identical to kitty's `background #000000` +
    # `background_opacity 0.65`, which is the parity this whole thing exists to
    # achieve. Change this one string to reweight the glass.
    b'const A=".65",G="rgba(0,0,0,"+A+")",S="rgba(15,15,15,"+A+")";'
    b'const d="--bg-000:0 0% 0%!important;--bg-100:0 0% 0%!important;'
    b"--df-bg-page-hsl:0 0% 0%!important;--df-bg-page:#000!important;"
    b"--surface-primary:#000!important;--df-surface-primary:0 0% 0%!important;"
    b'--claude-background-color:#000!important";'
    # The layer assignment is MEASURED, not guessed (live probe, 88 sample
    # points over the real window). Exactly four things paint full-window area:
    #
    #   html.cds-root           already transparent
    #   body.bg-surface-1       rgb(21,21,21)  <- the grey floor, from
    #                           --cds-surface-1; a THIRD token vocabulary
    #                           (cds-*) that neither bg-* nor df-* rules reach
    #   main.dframe-content     opaque
    #   div.dframe-content-inner opaque   (60 of 88 points)
    #   aside.dframe-sidebar    opaque    (16 of 88 points)
    #
    # Only ONE of them may carry alpha. Stacking two translucent full-area
    # layers multiplies them and leaves exactly the uneven patches this is
    # meant to remove -- so body carries the glass and the layers above it go
    # fully transparent. Everything that is CONTENT rather than chrome (images,
    # the PDF thumbnail, canvases) is untouched and therefore stays opaque,
    # which is the point: glass backgrounds, solid content.
    #
    # The sidebar keeps its faint separation -- rgb(15,15,15) at the same 0.65
    # is what the old hsl(0 0% 6%) composited to under whole-window opacity, so
    # the look is preserved rather than reinvented.
    b'const r=p=>p+" body,"+p+" .bg-surface-1,"+p+"body{background-color:"+G+"!important}"'
    b'+p+" .dframe-root,"+p+" .dframe-content,"+p+" .dframe-content-inner'
    b'{background-color:transparent!important}"'
    b'+p+" .dframe-sidebar{background-color:"+S+"!important}";'
    # TWO gates: 1.40609.1 keys its dark rules off a [data-mode=dark] attribute
    # (17 occurrences in the bundled CSS against 1 for prefers-color-scheme), so
    # a media-query-only gate misses "dark in the app, light in the OS". The
    # media block also bows out when the app has explicitly said light.
    b'const css="@media (prefers-color-scheme: dark){"'
    b'+":root:not([data-mode=light]),:root:not([data-mode=light]) *{"+d+"}"'
    b'+r(":root:not([data-mode=light])")+"}"'
    b'+"[data-mode=dark],[data-mode=dark] *{"+d+"}"'
    b'+r("[data-mode=dark]");'
    b"const a=()=>{try{const s=new CSSStyleSheet();s.replaceSync(css);"
    b"document.adoptedStyleSheets=[...document.adoptedStyleSheets,s]}"
    b'catch(e){const t=document.createElement("style");t.textContent=css;'
    b"document.documentElement.appendChild(t)}};"
    b'document.readyState==="loading"'
    b'?document.addEventListener("DOMContentLoaded",a):a()'
    b"}catch(e){}})();\n"
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

    missing = set(PRELOAD_PATHS) - injected
    if missing:
        sys.exit(f"blacken: preload(s) not found -- renamed? {sorted(missing)}")

    # PER-GROUP, not a bare total. Upstream moved 13 of these in 1.40609.1
    # -- the gray ramp renumbered, --claude-background-color went #262624 ->
    # #151515, the Electron window color turned from a quoted ternary into a
    # backtick object literal -- while enough of the rest still matched that a
    # "did anything hit?" check passed and the window chrome quietly stayed
    # grey. Every group must land, so the next such drift stops the build with
    # the name of what moved instead of shipping a half-black theme.
    dead = sorted(g for g, c in GROUP_HITS.items() if c == 0)
    if dead:
        sys.exit(
            "blacken: these replacement groups matched NOTHING -- upstream "
            f"changed them: {dead}\n"
            "  re-derive the current spellings from the unpacked asar before "
            "editing REPLACEMENTS; every entry is a same-length byte patch."
        )
    print(
        "blacken: groups "
        + ", ".join(f"{g}={GROUP_HITS[g]}" for g in sorted(GROUP_HITS))
    )


if __name__ == "__main__":
    main(Path(sys.argv[1]))
