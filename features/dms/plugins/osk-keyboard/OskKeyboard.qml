import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "layouts.js" as Layouts

/*
  On-screen keyboard, in QML. Replaced wvkbd (2026-10-08) for three reasons: wvkbd
  ignores the S Pen (it has no tablet input; a Quickshell surface gets tablet
  points delivered to its pointer handlers), it had no Super key, and it could
  only be themed so far. Modelled on end-4/dots-hyprland's illogical-impulse OSK
  (layout data + per-key components, evdev keycodes).

  Keys go out through osk-vk (./vk): ONE persistent Wayland virtual keyboard with
  the US keymap, fed press/release lines on stdin. Not ydotool (needs a root
  daemon and /dev/uinput, root-only here) and not wtype: wtype makes a new virtual
  keyboard with its own keymap per call, Hyprland hands every new keymap to the
  input method, and a burst of them hung fcitx5 -- a held arrow key repeating
  through wtype did exactly that, and the backlog kept typing after release.
  osk-vk's keys reach Hyprland like hardware: binds fire (Super+C, Super+PgUp
  verified), fcitx composes Hangul (ㅎㅏㄴ -> 한), Shift and Caps work through the
  keymap, and a held key repeats natively.

  A daemon plugin: ONE keyboard window, driven over IPC (`dms ipc call osk
  toggle|show|hide|pin|unpin|togglePin|state`) and by the osk-toggle bar pill,
  which reaches this instance through pluginService.pluginDaemonInstances.
*/
PluginComponent {
    id: root

    // --- state ---------------------------------------------------------------
    property bool shown: false
    property bool pinned: pluginData.pinned === true
    property int sizeIdx: pluginData.sizeIdx !== undefined ? pluginData.sizeIdx : 1
    property real floatX: pluginData.floatX !== undefined ? pluginData.floatX : -1   // -1: centred
    property real floatY: pluginData.floatY !== undefined ? pluginData.floatY : 16
    readonly property var floatWidths: [900, 1200, 1500]

    // modifiers: 0 off, 1 one-shot (next key), 2 locked. A new object on every
    // change so the keys' bindings see it.
    property var mods: ({ shift: 0, ctrl: 0, alt: 0, logo: 0 })
    property var modTapAt: ({})
    property bool caps: false
    readonly property bool shiftOn: mods.shift > 0
    readonly property bool shifted: shiftOn
    readonly property bool otherModsOn: mods.ctrl > 0 || mods.alt > 0 || mods.logo > 0

    // fcitx's state, as fcitx reports it (fcitx5-remote -n), never tracked locally
    property bool korean: false
    // Hangul labels give way to Latin while Ctrl/Alt/Super/AltGr is active:
    // shortcuts are Latin keys whatever the IME says, and fcitx's Hangul engine
    // passes modified keys through untranslated. Shift alone keeps Hangul.
    readonly property bool showHangul: korean && !otherModsOn

    // Dubeolsik legends for the Latin keysyms
    readonly property var jamo: ({
        q: { l: "ㅂ", s: "ㅃ" }, w: { l: "ㅈ", s: "ㅉ" }, e: { l: "ㄷ", s: "ㄸ" }, r: { l: "ㄱ", s: "ㄲ" },
        t: { l: "ㅅ", s: "ㅆ" }, y: { l: "ㅛ" }, u: { l: "ㅕ" }, i: { l: "ㅑ" }, o: { l: "ㅐ", s: "ㅒ" },
        p: { l: "ㅔ", s: "ㅖ" }, a: { l: "ㅁ" }, s: { l: "ㄴ" }, d: { l: "ㅇ" }, f: { l: "ㄹ" },
        g: { l: "ㅎ" }, h: { l: "ㅗ" }, j: { l: "ㅓ" }, k: { l: "ㅏ" }, l: { l: "ㅣ" },
        z: { l: "ㅋ" }, x: { l: "ㅌ" }, c: { l: "ㅊ" }, v: { l: "ㅍ" }, b: { l: "ㅠ" },
        n: { l: "ㅜ" }, m: { l: "ㅡ" }
    })

    // --- public API (IPC, bar pill) ------------------------------------------
    function toggle() { setShown(!shown) }
    function setShown(v) {
        shown = v
        if (!v) releaseAll()
        else refreshIme()
    }
    function setPinned(v) { pinned = v; save("pinned", v) }
    function save(k, v) { if (pluginService) pluginService.savePluginData(pluginId, k, v) }

    IpcHandler {
        target: "osk"
        function toggle(): string { root.toggle(); return root.shown ? "shown" : "hidden" }
        function show(): string { root.setShown(true); return "shown" }
        function hide(): string { root.setShown(false); return "hidden" }
        function pin(): string { root.setPinned(true); return "pinned" }
        function unpin(): string { root.setPinned(false); return "floating" }
        function togglePin(): string { root.setPinned(!root.pinned); return root.pinned ? "pinned" : "floating" }
        function state(): string { return (root.shown ? "shown" : "hidden") + " " + (root.pinned ? "pinned" : "floating") + " " + (root.korean ? "ko" : "en") }
    }

    // --- keys ----------------------------------------------------------------
    // Keys are real key presses on ONE persistent virtual keyboard (osk-vk, a small
    // helper this plugin keeps running): "d <code>" on press, "u <code>" on release,
    // evdev codes as on the physical keyboard. So a held key is held (clients repeat
    // it themselves), Shift/Caps produce capitals and symbols through the normal US
    // keymap, and Hyprland binds see what hardware would send.
    function vk(cmd) { if (vkProc.running) vkProc.write(cmd + "\n") }

    // A modifier is a real press of its key. One tap holds it for the next key
    // (one-shot), a second tap within 400 ms locks it, a tap on a locked one -- or
    // a slower second tap -- releases it.
    function setMod(m, next) {
        const prev = mods[m] || 0
        if (prev === 0 && next > 0) vk("d " + Layouts.modCodes[m])
        else if (prev > 0 && next === 0) vk("u " + Layouts.modCodes[m])
        const n = Object.assign({}, mods); n[m] = next; mods = n
    }
    function modTap(m) {
        const now = Date.now()
        const st = mods[m] || 0
        let next
        if (st === 0) next = 1
        else if (st === 1) next = (now - (modTapAt[m] || 0) < 400) ? 2 : 0
        else next = 0
        const t = Object.assign({}, modTapAt); t[m] = now; modTapAt = t
        setMod(m, next)
        if (next > 0) modPressedAt = now
    }
    property real modPressedAt: 0
    function clearOneShots() {
        for (const m in mods) if (mods[m] === 1) setMod(m, 0)
    }
    function releaseAll() {
        vk("x")
        mods = ({ shift: 0, ctrl: 0, alt: 0, logo: 0 })
        held = ({})
    }

    // keys currently down on the keyboard, by code: a release always matches a press
    property var held: ({})
    function keyDown(d) {
        const t = d.t || "key"
        if (t === "mod") return modTap(d.mod)
        if (t === "caps") { caps = !caps; vk("d " + Layouts.capsCode); vk("u " + Layouts.capsCode); return }
        if (t === "action") {
            if (d.act === "pin") setPinned(!pinned)
            else if (d.act === "hide") setShown(false)
            else if (d.act === "size") { sizeIdx = (sizeIdx + 1) % floatWidths.length; save("sizeIdx", sizeIdx) }
            else if (d.act === "ime") { imeToggle.running = true }
            return
        }
        if (d.c === undefined) return
        const h = Object.assign({}, held); h[d.c] = true; held = h
        // A modifier pressed in the same instant as the key can race Hyprland's
        // bare-Super binds (the workspace peek): measured, Super+PgUp fired with
        // 100 ms between the presses and not when they arrived together.
        const gap = Date.now() - modPressedAt
        if (gap < 30) { pending.code = d.c; pending.start() }
        else vk("d " + d.c)
    }
    function keyUp(d) {
        if ((d.t || "key") !== "key" || d.c === undefined || !held[d.c]) return
        const h = Object.assign({}, held); delete h[d.c]; held = h
        if (pending.running && pending.code === d.c) { pending.stop(); vk("d " + d.c) }
        vk("u " + d.c)
        clearOneShots()
    }
    Timer {
        id: pending
        property int code: 0
        interval: 30
        onTriggered: root.vk("d " + code)
    }

    Process {
        id: vkProc
        // osk-vk is on PATH (features/dms/plugins.nix builds it with the plugin)
        command: ["osk-vk"]
        stdinEnabled: true
        running: true
        onExited: vkRestart.start()   // died (display reset etc.): come back
    }
    Timer { id: vkRestart; interval: 1000; onTriggered: vkProc.running = true }

    // --- fcitx state ---------------------------------------------------------
    // fcitx5's D-Bus controller has no state-change signal (only
    // InputMethodGroupsChanged), so the state is re-read: after every toggle, on
    // every focus change (fcitx may keep per-window input state), and every 500 ms
    // while the keyboard is up.
    function refreshIme() { if (!imeQuery.running) imeQuery.running = true }
    Process {
        id: imeQuery
        command: ["fcitx5-remote", "-n"]
        stdout: StdioCollector { onStreamFinished: root.korean = this.text.trim() === "hangul" }
    }
    Process {
        id: imeToggle
        command: ["fcitx5-remote", "-t"]
        onExited: root.refreshIme()
    }
    Timer { interval: 500; repeat: true; running: root.shown; onTriggered: root.refreshIme() }
    Connections {
        target: Hyprland
        function onRawEvent(event) { if (root.shown && event.name === "activewindow") root.refreshIme() }
    }

    // --- window --------------------------------------------------------------
    /*
      Show/hide animation: the keyboard slides up from the bottom edge and fades in,
      and the reverse. Hyprland does not animate it (the dms-* layer rule sets no_anim,
      which the bar wants), so it is done here. The window stays mapped until the
      slide-out ends, or hiding would cut it off at once. A pinned keyboard reserves
      its height when shown and gives it back when the window unmaps: animating the
      exclusive zone would resize every window on every frame.
    */
    property real reveal: shown ? 1 : 0
    Behavior on reveal { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    PanelWindow {
        id: win
        screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
        visible: root.shown || root.reveal > 0.001
        color: "transparent"

        // dms-* is blurred by features/dms/hyprland.lua's layer rule: the frosted glass
        WlrLayershell.namespace: "dms-osk"
        WlrLayershell.layer: WlrLayer.Overlay
        // never takes keyboard focus: the window being typed into keeps it
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        // pinned: reserve the height like the bar, so windows shrink above it
        WlrLayershell.exclusionMode: root.pinned ? ExclusionMode.Normal : ExclusionMode.Ignore
        exclusiveZone: root.pinned ? implicitHeight : 0

        readonly property real screenW: screen ? screen.width : 1920
        readonly property real kbW: root.pinned ? screenW : Math.min(root.floatWidths[root.sizeIdx], screenW - 16)
        readonly property real pad: 10
        readonly property real unit: (kbW - 2 * pad) / Layouts.units
        readonly property real keyH: Math.min(unit * 0.9, 72)

        // Floating: the window covers the whole output (transparent; input only where
        // the keyboard is drawn, see mask) and the keyboard moves INSIDE it. Moving the
        // layer surface itself made drags feed back on themselves -- its coordinates
        // moved with it, and margin changes land asynchronously, so mouse and pen drags
        // overshot and fell apart. Pinned: a strip along the bottom edge.
        readonly property real screenH: screen ? screen.height : 1200
        anchors { bottom: true; left: true; right: true; top: !root.pinned }
        implicitWidth: kbW
        implicitHeight: root.pinned ? body.implicitHeight : screenH

        // input only where the keyboard is drawn
        mask: Region { item: body }

        Rectangle {
            id: body
            width: win.kbW
            height: implicitHeight
            implicitHeight: col.implicitHeight + 2 * win.pad + (grip.visible ? grip.height : 0)
            x: root.pinned ? 0 : (root.floatX < 0 ? (win.screenW - win.kbW) / 2 : Math.min(root.floatX, win.screenW - win.kbW))
            // win.height, not the screen's: the full-output window starts below the
            // bar's exclusive zone (measured: y 42, height 1158 of 1200)
            y: root.pinned ? 0 : Math.max(0, win.height - root.floatY - height)
            color: Theme.withAlpha(Theme.surface, 0.55)
            // the show/hide slide (root.reveal): down by its own height plus a margin
            // at 0, in place at 1
            opacity: root.reveal
            transform: Translate { y: (1 - root.reveal) * (body.height + 24) }
            radius: root.pinned ? 0 : 20
            border.width: root.pinned ? 0 : 1
            border.color: Theme.withAlpha(Theme.outlineVariant, 0.6)

            // floating: drag the keyboard by this grip
            Item {
                id: grip
                visible: !root.pinned
                width: parent.width
                height: 18
                Rectangle {
                    anchors.centerIn: parent
                    width: 56; height: 5; radius: 3
                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.6)
                }
                DragHandler {
                    id: drag
                    target: null
                    acceptedDevices: PointerDevice.AllDevices
                    // the window does not move, so translation is a stable screen offset
                    property real x0: 0
                    property real y0: 0
                    onActiveChanged: {
                        if (active) {
                            x0 = body.x
                            y0 = body.y
                        } else {
                            root.save("floatX", root.floatX)
                            root.save("floatY", root.floatY)
                        }
                    }
                    onTranslationChanged: {
                        if (!active) return
                        const nx = Math.max(0, Math.min(win.screenW - win.kbW, x0 + translation.x))
                        const ny = Math.max(0, Math.min(win.height - body.height, y0 + translation.y))
                        root.floatX = nx
                        root.floatY = win.height - ny - body.height   // kept as distance from the bottom
                    }
                }
            }

            Column {
                id: col
                x: win.pad
                y: win.pad + (grip.visible ? grip.height : 0)
                spacing: 0
                Repeater {
                    model: Layouts.rows
                    Row {
                        required property var modelData
                        required property int index
                        readonly property real rowUnit: (win.kbW - 2 * win.pad) / Layouts.rowUnits(modelData)
                        Repeater {
                            id: rowKeys
                            model: parent.modelData
                            // a plain key, or a slot holding two half-height keys
                            // (the Up/Down arrows), each its own touch target
                            Item {
                                id: slot
                                required property var modelData
                                readonly property real h: parent.index === 0 ? win.keyH * 0.62 : win.keyH
                                width: parent.rowUnit * (modelData.w || 1)
                                height: h
                                OskKey {
                                    visible: !slot.modelData.stack
                                    keyData: slot.modelData.stack ? slot.modelData.stack[0] : slot.modelData
                                    kbd: slot.modelData.stack ? null : root
                                    unit: slot.parent.rowUnit
                                    keyHeight: slot.h
                                }
                                Column {
                                    visible: !!slot.modelData.stack
                                    Repeater {
                                        model: slot.modelData.stack || []
                                        OskKey {
                                            required property var modelData
                                            keyData: modelData
                                            kbd: root
                                            unit: slot.parent.rowUnit
                                            keyHeight: slot.h / 2
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
