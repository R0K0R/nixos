// Key layout for the on-screen keyboard (OskKeyboard.qml).
//
// A key is { l, s, c, k, w, t, mod, act, stack }:
//   l    label              s    label with Shift (also the corner legend)
//   c    evdev keycode, sent to osk-vk as press/release -- the same codes the
//        physical keyboard produces (/usr/include/linux/input-event-codes.h), so
//        Shift, Caps, held keys and repeat behave exactly like hardware
//   k    the letter, for the Hangul legends (OskKeyboard.jamo)
//   w    width in key units (default 1)
//   t    "key" (default) | "mod" | "caps" | "action"
//   mod  for t:"mod": shift | ctrl | alt | logo
//   act  for t:"action": pin | hide | size | ime (fcitx toggle, fcitx5-remote -t)
//   stack: [top, bottom] -- two half-height keys in one slot (the Up/Down arrows)
// The 한/영 key asks fcitx itself to toggle instead of sending a hotkey, and the
// labels follow fcitx's reported state.
.pragma library

function K(l, s, c, w) { return { l: l, s: s, c: c, w: w || 1 }; }          // symbol / digit key
function A(ch, c) { return { l: ch, s: ch.toUpperCase(), c: c, k: ch }; }     // letter
function N(l, c, w) { return { l: l, c: c, w: w || 1 }; }                     // named key

// the modifier keys' codes: Shift_L, Control_L, Alt_L, Super_L
const modCodes = { shift: 42, ctrl: 29, alt: 56, logo: 125 };
const capsCode = 58;

const rows = [
    // function row (drawn at half height; its keys are narrower -- every row is
    // stretched to the full width), with the keyboard's own controls first
    [{ l: "pin", t: "action", act: "pin" }, { l: "size", t: "action", act: "size" },
     { l: "hide", t: "action", act: "hide" }, N("Esc", 1),
     N("F1", 59), N("F2", 60), N("F3", 61), N("F4", 62), N("F5", 63), N("F6", 64),
     N("F7", 65), N("F8", 66), N("F9", 67), N("F10", 68), N("F11", 87), N("F12", 88),
     N("PrtSc", 99), N("Home", 102), N("End", 107), N("PgUp", 104), N("PgDn", 109), N("Del", 111)],
    [K("`", "~", 41), K("1", "!", 2), K("2", "@", 3), K("3", "#", 4), K("4", "$", 5),
     K("5", "%", 6), K("6", "^", 7), K("7", "&", 8), K("8", "*", 9), K("9", "(", 10),
     K("0", ")", 11), K("-", "_", 12), K("=", "+", 13), N("⌫", 14, 2)],
    [N("Tab", 15, 1.5), A("q", 16), A("w", 17), A("e", 18), A("r", 19), A("t", 20),
     A("y", 21), A("u", 22), A("i", 23), A("o", 24), A("p", 25),
     K("[", "{", 26), K("]", "}", 27), K("\\", "|", 43, 1.5)],
    [{ l: "Caps", t: "caps", w: 1.8 }, A("a", 30), A("s", 31), A("d", 32), A("f", 33),
     A("g", 34), A("h", 35), A("j", 36), A("k", 37), A("l", 38),
     K(";", ":", 39), K("'", "\"", 40), N("Enter", 28, 2.2)],
    [{ l: "Shift", t: "mod", mod: "shift", w: 2.3 }, A("z", 44), A("x", 45), A("c", 46),
     A("v", 47), A("b", 48), A("n", 49), A("m", 50),
     K(",", "<", 51), K(".", ">", 52), K("/", "?", 53), { l: "Shift", t: "mod", mod: "shift", w: 2.7 }],
    [{ l: "Ctrl", t: "mod", mod: "ctrl", w: 1.3 }, { l: "Super", t: "mod", mod: "logo", w: 1.3 },
     { l: "Alt", t: "mod", mod: "alt", w: 1.2 }, N("", 57, 6.9),
     { l: "한/영", t: "action", act: "ime", w: 1.3 },
     // laptop-style inverted T: Up stacked over Down at half height between Left and Right
     N("←", 105), { w: 1, stack: [N("↑", 103), N("↓", 108)] }, N("→", 106)]
];

function rowUnits(row) {
    let u = 0;
    for (const k of row) u += (k.w || 1);
    return u;
}

// Every row but the function row is 15 units; the key unit is width / 15.
const units = 15;
