import QtQuick
import qs.Common
import qs.Widgets

// One key. Input is a TapHandler accepting every pointer device: each key owns its
// own touch point, so two fingers on two keys are two independent presses (fast
// typing), and the S Pen arrives as a stylus point -- Qt delivers tablet input
// to pointer handlers directly, which is what wvkbd lacked.
Item {
    id: key

    required property var keyData   // a layouts.js key
    property var kbd                // the keyboard (OskKeyboard.qml): state + send()
    property real unit: 60
    property real keyHeight: 56

    readonly property string type: keyData.t || "key"
    readonly property bool isMod: type === "mod"
    readonly property int modState: isMod && kbd ? (kbd.mods[keyData.mod] || 0) : 0   // 0 off, 1 one-shot, 2 locked
    readonly property bool lit: (isMod && modState > 0) || (type === "caps" && kbd && kbd.caps)
        || (type === "action" && keyData.act === "pin" && kbd && kbd.pinned)
        || (type === "action" && keyData.act === "ime" && kbd && kbd.korean)
    readonly property bool down: tap.pressed

    width: unit * (keyData.w || 1)
    height: keyHeight

    function label() {
        if (type === "action") {
            if (keyData.act === "ime") return kbd && kbd.korean ? "한" : "EN";
            return "";
        }
        if (type !== "key") return keyData.l;
        // what Shift/Caps would make this key send: letters follow Shift XOR Caps,
        // everything else Shift alone (OskKeyboard.emitKey's rule)
        const letter = /^[a-z]$/.test(keyData.k);
        const shifted = kbd && (letter ? (kbd.shiftOn !== kbd.caps) : kbd.shiftOn);
        // Korean labels follow fcitx's reported state (kbd.korean), never a local
        // guess, and give way to Latin while Ctrl/Alt/Super/AltGr is active
        // (kbd.showHangul): shortcuts are Latin keys whatever the IME says. The key
        // sends the same keysym either way -- fcitx composes.
        if (kbd && kbd.showHangul && kbd.jamo[keyData.k] !== undefined) {
            const j = kbd.jamo[keyData.k];
            return kbd.shiftOn && j.s ? j.s : j.l;   // Shift picks ㅃㅉㄸㄲㅆㅒㅖ; Caps doesn't
        }
        if (shifted && keyData.s) return keyData.s;
        return keyData.l;
    }
    function icon() {
        if (type !== "action") return "";
        return ({ pin: "push_pin", hide: "keyboard_hide", size: "aspect_ratio" })[keyData.act] || "";
    }

    Rectangle {
        id: cap
        anchors.fill: parent
        anchors.margins: Math.max(2, key.unit * 0.05)
        radius: Math.min(height, width) * 0.22
        color: key.lit ? Theme.primary
             : key.down ? Theme.surfaceContainerHighest
             : (key.type === "key" ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.92)
                                   : Theme.withAlpha(Theme.surfaceContainer, 0.92))
        border.width: key.isMod && key.modState === 2 ? 2 : 0
        border.color: Theme.onPrimary
        scale: key.down ? 0.94 : 1
        Behavior on scale { NumberAnimation { duration: 70; easing.type: Easing.OutQuad } }
        Behavior on color { ColorAnimation { duration: 90 } }

        // secondary (shifted) legend in the corner, like a physical key
        Text {
            visible: key.type === "key" && !!key.keyData.s && !(key.kbd && key.kbd.showHangul && key.kbd.jamo[key.keyData.k])
                     && key.keyData.s.toLowerCase() !== key.keyData.l
            text: key.keyData.s || ""
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: parent.height * 0.1
            font.pixelSize: parent.height * 0.22
            color: Theme.surfaceVariantText
        }
        Text {
            visible: key.icon() === ""
            anchors.centerIn: parent
            text: key.label()
            // short legends by the smaller side, so a half-height arrow key stays readable
            font.pixelSize: key.type === "key" && key.label().length <= 2
                ? Math.min(parent.height * 0.62, parent.width * 0.42)
                : Math.min(parent.height * 0.34, parent.width * 0.3)
            font.weight: Font.Medium
            color: key.lit ? Theme.onPrimary : Theme.surfaceText
        }
        DankIcon {
            visible: key.icon() !== ""
            anchors.centerIn: parent
            name: key.icon()
            size: parent.height * 0.5
            filled: key.lit
            color: key.lit ? Theme.onPrimary : Theme.surfaceText
        }
    }

    TapHandler {
        id: tap
        acceptedDevices: PointerDevice.AllDevices
        acceptedPointerTypes: PointerDevice.AllPointerTypes
        gesturePolicy: TapHandler.WithinBounds
        // fire on PRESS for typing latency; release only ends a repeat
        onPressedChanged: {
            if (!key.kbd) return;
            if (pressed) key.kbd.keyDown(key.keyData);
            else key.kbd.keyUp(key.keyData);
        }
    }
}
