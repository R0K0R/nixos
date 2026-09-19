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
    # The claude.ai content is a WebContentsView laid over the window, and it is
    # created with no setBackgroundColor at all -- so it keeps Electron's
    # default view background and the transparent window behind it never shows
    # through. No amount of page CSS can fix that: the fill is the VIEW's, not
    # the document's. It is why the pane stayed a flat #111111 that the palette
    # sweep could not touch, while regions outside the view showed through.
    (
        "claude-view-transparent",
        b"return V=new o.WebContentsView(e),ui(V.webContents,li.CLAUDE_AI_WEB)",
        b"return V=new o.WebContentsView(e),V.setBackgroundColor(`#00000000`),"
        b"ui(V.webContents,li.CLAUDE_AI_WEB)",
    ),
    # And the window's own transparency was being undone after the fact. A
    # nativeTheme `updated` handler calls setBackgroundColor(_P()), and _P()
    # returns the patched-to-opaque #000000, so the window is created
    # transparent and then made opaque again on the first theme update. Pinned
    # to the transparent literal here rather than changing _P(), which the
    # About and 3P-inference windows also use and which must stay opaque.
    (
        "theme-update-keeps-transparent",
        b"Ra?.setBackgroundColor(_P())",
        b"Ra?.setBackgroundColor(`#00000000`)",
    ),
    # The window-controls strip (min/max/close) is Electron's native
    # titleBarOverlay, painted outside any document, so no preload CSS reaches
    # it. Its colour comes from gP(): `t = gKt ? EKt(_P()) : _P()`, and gKt is
    # !1, so t is just _P() -- the fKt.dark we patched to opaque #000000. That
    # is the black box in the corner. Pinning t to a transparent literal changes
    # the overlay and nothing else: both theme branches read `t`, and _P()
    # itself is untouched for the windows that must stay opaque.
    (
        "title-bar-overlay-transparent",
        b"t=gKt?EKt(_P()):_P()",
        b"t=`#00000000`",
    ),
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
# Written as str pieces and encoded once at the end. The historical style here
# was concatenated bytes literals, which made a single mistyped prefix fail with
# "cannot mix bytes and nonbytes literals" pointing at the closing paren rather
# than at the bad line.
PRELOAD_JS = (
    "\n;(()=>{try{"
    # ALPHA lives in the surface, not in a compositor opacity rule. 0.65 black
    # is kitty's `background #000000` + `background_opacity 0.65`.
    'const A=".65",G="rgba(0,0,0,"+A+")",SB="rgba(255,255,255,.05)";'
    'const d="--bg-000:0 0% 0%!important;--bg-100:0 0% 0%!important;'
    "--df-bg-page-hsl:0 0% 0%!important;--df-bg-page:#000!important;"
    "--surface-primary:#000!important;--df-surface-primary:0 0% 0%!important;"
    '--claude-background-color:#000!important";'

    # EXACTLY ONE LAYER MAY CARRY THE BASE ALPHA, and this window has more
    # layers than it looks: the shell page (file://) and the claude.ai
    # WebContentsView laid over it, both of which get this preload. Giving both
    # a 0.65 body composited to 1-0.35^2 = 0.88, and the sidebar's own 0.65 on
    # top made three -- 0.96, visually opaque. So the SHELL carries the base,
    # since it is the one surface spanning the whole window, and the remote
    # document goes transparent on top of it.
    'const shell=location.protocol==="file:";'
    # background-IMAGE too. A full-window overlay --
    # div.pointer-events-none.absolute.inset-0.bg-surface-1 -- paints a
    # linear-gradient that is opaque over the sidebar and fades across the pane.
    # Its background-COLOR was already transparent, so resetting only that did
    # nothing, and pointer-events:none kept it out of elementsFromPoint.
    'const T="{background-color:transparent!important;background-image:none!important}";'
    # In the SHELL, body carries the glass AND everything inside it goes
    # transparent. Those children are the boot placeholder -- the fake chrome
    # the shell paints so the window is not empty while claude.ai loads: a
    # sidebar with skeleton rows, and the strip behind the window controls.
    #
    # It is drawn UNDER the claude.ai view, so it was invisible until the view
    # became transparent -- at which point we started seeing through the real
    # sidebar to the fake one behind it. That is why every probe of the
    # claude.ai document truthfully reported nothing painting there, and why
    # the skeleton rows persist long after sign-in: they were never the live
    # app's skeletons.
    "const r=(a,self)=>shell"
    '?(a+" body"+(self?","+self:"")+"{background-color:"+G+"!important}"'
    '+a+" body *"+T)'
    ':(a+","+a+" body,"+a+" .bg-surface-1,"+a+" .dframe-root,"'
    '+a+" .dframe-content,"+a+" .dframe-content-inner,"+a+" .dframe-sidebar"+T'
    # The sidebar gets its own surface -- a faint WHITE lift, not another dark
    # 0.65 layer. Same alpha stacked twice reads opaque (0.88); a 5% lift over
    # the shell's 0.65 base leaves total opacity at ~0.67, visibly a different
    # panel, still glass. One constant to retune.
    '+a+" .dframe-sidebar{background-color:"+SB+"!important}");'

    # TWO gates: 1.40609.1 keys dark off a [data-mode=dark] attribute (17
    # occurrences in the bundled CSS against 1 for prefers-color-scheme), so a
    # media-query-only gate misses "dark in the app, light in the OS".
    'const css="@media (prefers-color-scheme: dark){"'
    '+":root:not([data-mode=light]),:root:not([data-mode=light]) *{"+d+"}"'
    '+r(":root:not([data-mode=light])",null)+"}"'
    '+"[data-mode=dark],[data-mode=dark] *{"+d+"}"'
    '+r("[data-mode=dark]","body[data-mode=dark]");'

    # PALETTE SWEEP. Enumerating selectors does not converge -- there is always
    # another element, with another class, painting through another property.
    # The design tokens cannot be overridden ahead of time either: --cds-* is
    # defined in the REMOTE stylesheet, not in anything this package patches.
    #
    # So detect rather than enumerate. A surface belongs to the dark palette if
    # its computed background is OPAQUE, NEAR-NEUTRAL and DARK. That catches
    # every grey, hardcoded or tokenised, present at load or added later, while
    # leaving colour alone -- the amber banner, buttons and syntax highlighting
    # all fail the neutrality test.
    # Two frost tiers. Static surfaces (pane, sidebar, cards) get PA/BLUR.
    # POSITIONED surfaces -- fixed, sticky, absolute: popups, menus, the
    # composer group, anything laid OVER scrolling content -- get PH/BLURH,
    # because a 0.55 panel with light blur over body text is unreadable in both
    # directions (see the composer with the conversation scrolling through it).
    'const PA=.55,BLUR="14px",PH=.85,BLURH="24px";'
    # Parses BOTH serialisations Chromium emits: legacy rgb()/rgba(), and
    # color(srgb r g b / a) with 0-1 floats, which is what any colour authored
    # with color-mix()/oklch()/color() comes back as. The first version only
    # read rgb(), so every modern-syntax surface was silently skipped -- the
    # probe reported them as "unparsed".
    "const pal=c=>{let m=/^rgba?\\((\\d+), ?(\\d+), ?(\\d+)(?:, ?([\\d.]+))?\\)$/.exec(c||\"\"),R,G2,B,al;"
    "if(m){R=+m[1];G2=+m[2];B=+m[3];al=m[4]===undefined?1:+m[4];}"
    "else{m=/^color\\((?:srgb|display-p3) ([\\d.]+) ([\\d.]+) ([\\d.]+)(?: \\/ ([\\d.]+))?\\)$/.exec(c||\"\");"
    "if(!m)return null;R=Math.round(+m[1]*255);G2=Math.round(+m[2]*255);B=Math.round(+m[3]*255);al=m[4]===undefined?1:+m[4];}"
    # al<1: something already made it glass -- ours or theirs. Leave it, or
    # repeated sweeps would compound the alpha every pass.
    "if(al<1)return null;const mx=Math.max(R,G2,B),mn=Math.min(R,G2,B);"
    # mx<=64 keeps to dark surfaces; mx-mn<=12 keeps to neutrals.
    "if(mx>64||mx-mn>12)return null;return[R,G2,B];};"
    "const done=new WeakSet();"
    # Heavy tier: positioned overlays, PLUS anything that contains a text input.
    # The composer is the case that forced the second clause -- its rows are
    # position:relative and 48px tall, so they dodge both the positioned test
    # and the blur size gate, yet the conversation scrolls directly under them.
    # "Contains an editable" is a positioning-independent way to say "this is
    # the input chrome", and it holds for any chat UI, not just this one.
    "const hasEdit=el=>!!(el.querySelector&&el.querySelector(\"textarea,[contenteditable=true],[contenteditable=\\\"\\\"],[role=textbox]\"));"
    "const heavyOf=(cs,el)=>{const p=cs.position;return p===\"fixed\"||p===\"sticky\"||p===\"absolute\"||(el&&hasEdit(el));};"
    # Blur is applied by size, but size is re-checked on later sweeps for
    # anything already marked: the first version measured once, at first
    # sight, so a surface treated before layout kept its alpha and never got
    # its blur -- which is exactly how the composer ended up see-through.
    "const blurIf=(el,st,cs)=>{if(el.dataset.glassBlur)return;const bb=el.getBoundingClientRect();const hv=heavyOf(cs,el);"
    "if(bb.width>180&&(bb.height>90||(hv&&bb.height>36))){const b=hv?BLURH:BLUR;"
    'st.setProperty("backdrop-filter","blur("+b+")","important");'
    'st.setProperty("-webkit-backdrop-filter","blur("+b+")","important");el.dataset.glassBlur=\"1\";}};'
    "const treat=el=>{if(done.has(el))return;const cs=getComputedStyle(el);const st=el.style;let hit=false;"
    "const q=pal(cs.backgroundColor);const A2=heavyOf(cs,el)?PH:PA;"
    'if(q){st.setProperty("background-color","rgba("+q[0]+","+q[1]+","+q[2]+","+A2+")","important");hit=true;}'
    # Gradients too. A gradient's stops are colours in the palette like any
    # other; the bottom scroll-fade is linear-gradient(to top, rgb(21,21,21),
    # transparent), and its opaque stop survived every colour-only pass.
    "const bi=cs.backgroundImage;if(bi&&bi!==\"none\"&&bi.indexOf(\"gradient(\")!==-1){let ch=false;"
    "const nb=bi.replace(/rgba?\\([^)]*\\)|color\\((?:srgb|display-p3)[^)]*\\)/g,t=>{const g=pal(t);if(!g)return t;ch=true;return\"rgba(\"+g.join(\",\")+\",\"+A2+\")\";});"
    'if(ch){st.setProperty("background-image",nb,"important");hit=true;}}'
    "if(!hit)return;done.add(el);el.dataset.glass=\"1\";blurIf(el,st,cs);};"
    "const upgrade=()=>{document.querySelectorAll(\"[data-glass]:not([data-glass-blur])\").forEach(el=>blurIf(el,el.style,getComputedStyle(el)));};"
    'const sweep=()=>{try{document.querySelectorAll("*").forEach(treat);upgrade();}catch(e){}};'
    # Debounced: a chat app mutates constantly and an unthrottled observer
    # would walk the whole tree for every streamed token.
    "let tm=0;const kick=()=>{clearTimeout(tm);tm=setTimeout(sweep,220);};"
    # Added subtrees are treated SYNCHRONOUSLY in the observer callback, which
    # runs as a microtask before the next paint -- so a popup never gets a
    # frame in its opaque colour. The debounced full sweep stays as the
    # catch-all. Capped per record so a streaming reply (hundreds of tiny
    # spans) cannot turn into hundreds of forced style recalcs; anything past
    # the cap is picked up by the debounced pass.
    "const treatTree=(n,cap)=>{if(!n||n.nodeType!==1)return;treat(n);"
    "if(!n.querySelectorAll)return;const l=n.querySelectorAll(\"*\");"
    "for(let i=0;i<l.length&&i<cap;i++)treat(l[i]);};"
    "const onMut=ms=>{for(const m of ms){"
    'if(m.type==="childList"){for(const n of m.addedNodes)treatTree(n,500);}'
    # A class/style change can swap in a new opaque colour on an element we
    # already treated. Forget it and look again; our inline !important still
    # wins when the computed colour is already ours, so this cannot compound.
    "else if(m.target&&m.target.nodeType===1){done.delete(m.target);treat(m.target);}}kick();};"
    "const obs=()=>{try{new MutationObserver(onMut).observe(document.documentElement,"
    '{childList:!0,subtree:!0,attributes:!0,attributeFilter:["class","style"]});}catch(e){}};'

    "const a=()=>{try{const s=new CSSStyleSheet();s.replaceSync(css);"
    "document.adoptedStyleSheets=[...document.adoptedStyleSheets,s]}"
    'catch(e){const t=document.createElement("style");t.textContent=css;'
    "document.documentElement.appendChild(t)}};"
    # Re-sweeps because the app paints late: skeletons first, real surfaces
    # after the session resolves.
    "const boot=()=>{a();sweep();obs();setTimeout(sweep,1200);setTimeout(sweep,4000);};"
    'document.readyState==="loading"'
    '?document.addEventListener("DOMContentLoaded",boot):boot()'
    "}catch(e){}})();\n"
).encode()

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
