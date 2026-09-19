import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Common
import qs.Services
import qs.Modules.Plugins

/*
  Region screenshot to the clipboard, drawn as an in-shell Quickshell
  overlay instead of a slurp region.

  WHY NOT slurp/hyprshot. slurp is a bare wlr client: it binds only
  wl_pointer and wl_touch, never zwp_tablet_manager_v2 (confirmed against
  slurp 1.5.0's registry -- it has no tablet symbols at all). Hyprland
  0.56 routes an S Pen tip ONLY through the tablet protocol
  (Tablets.cpp onTabletTip -> PROTO::tablet->down, no pointer-button
  emulation), so the pen moves the cursor over slurp but a tap/drag
  reaches it as nothing. No compositor or slurp option bridges that.

  A Quickshell window is a qtwayland client: it DOES bind the tablet
  protocol, and Qt synthesizes a mouse press from an unhandled tablet tip
  (AA_SynthesizeMouseForUnhandledTabletEvents, on by default), which a
  MouseArea handles like any click. So the pen just works here. This is
  exactly what end-4/dots-hyprland does (modules/waffle/screenSnip); this
  is a self-contained DMS port of that idea.

  MECHANISM. On trigger, one Overlay-layer PanelWindow per screen maps
  fully transparent. While transparent it runs `grim -o <output>` into a
  temp file -- the compositor output is unaltered at that instant, so the
  capture is clean and never contains our own dark overlay. When that
  frozen frame is ready it is shown as the background and darkened; a drag
  MouseArea (cross cursor, pen-capable) picks the rectangle. On release
  the region is cropped out of the temp with imagemagick and piped to
  wl-copy. Esc or right-click cancels. Coordinates are logical while
  selecting and multiplied by the screen scale for the crop, since grim
  captures at physical resolution.

  Bound in features/hyprland/home.nix (Print) and reachable as
  `dms ipc call screenSnip region`; the bar's Screenshot widget calls the
  same IPC. hyprshot stays wired as the fallback for when the shell is
  down.
*/
PluginComponent {
    id: root

    property bool active: false
    // Overridden per surface by the plugin loader; kept for completeness.
    property var popoutService: null

    property string savePath: (pluginData && pluginData.savePath) ? pluginData.savePath : ""

    function open() {
        active = true;
    }
    function close() {
        active = false;
    }

    IpcHandler {
        target: "screenSnip"
        function region(): string {
            root.open();
            return "ok";
        }
        function cancel(): string {
            root.close();
            return "ok";
        }
    }

    GlobalShortcut {
        appid: "dms-screensnip"
        name: "region"
        description: "Region screenshot to clipboard (pen-capable)"
        onPressed: root.open()
    }

    // One overlay per screen; emptying the model tears them all down.
    Variants {
        model: root.active ? Quickshell.screens : []

        PanelWindow {
            id: overlay

            required property var modelData
            screen: modelData

            // Physical/logical ratio; grim captures physical px, the MouseArea
            // measures logical px.
            readonly property real snipScale: modelData.devicePixelRatio > 0 ? modelData.devicePixelRatio : 1
            readonly property string tmpPath: "/tmp/dms-screensnip-" + modelData.name + ".png"
            property bool frozen: false

            WlrLayershell.namespace: "dms-screensnip"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            WlrLayershell.exclusiveZone: 0

            anchors {
                left: true
                right: true
                top: true
                bottom: true
            }
            color: "transparent"

            // Grab the clean frozen frame while the overlay is still fully
            // transparent (nothing of ours is composited yet).
            Process {
                id: grabProc
                command: ["grim", "-o", overlay.modelData.name, overlay.tmpPath]
                onExited: exitCode => {
                    if (exitCode === 0)
                        overlay.frozen = true;
                    else {
                        ToastService.showError("Screen Snip", "grim failed (" + exitCode + ")");
                        root.close();
                    }
                }
            }
            Component.onCompleted: Qt.callLater(() => grabProc.running = true)

            Process {
                id: snipProc
            }

            // Frozen background, shown only once captured.
            Image {
                anchors.fill: parent
                visible: overlay.frozen
                source: overlay.frozen ? ("file://" + overlay.tmpPath + "?t=" + Date.now()) : ""
                cache: false
                fillMode: Image.Stretch
            }

            // Four dim panels around the selection; the selection stays clear.
            readonly property int selX: Math.min(drag.startX, drag.curX)
            readonly property int selY: Math.min(drag.startY, drag.curY)
            readonly property int selW: Math.abs(drag.curX - drag.startX)
            readonly property int selH: Math.abs(drag.curY - drag.startY)
            readonly property bool hasSel: drag.active && selW > 0 && selH > 0

            Item {
                anchors.fill: parent
                visible: overlay.frozen
                Rectangle {
                    // top
                    color: "#000000"; opacity: 0.4
                    x: 0; y: 0; width: parent.width
                    height: overlay.hasSel ? overlay.selY : parent.height
                }
                Rectangle {
                    // bottom
                    color: "#000000"; opacity: 0.4
                    visible: overlay.hasSel
                    x: 0; y: overlay.selY + overlay.selH
                    width: parent.width; height: Math.max(0, parent.height - (overlay.selY + overlay.selH))
                }
                Rectangle {
                    // left
                    color: "#000000"; opacity: 0.4
                    visible: overlay.hasSel
                    x: 0; y: overlay.selY
                    width: overlay.selX; height: overlay.selH
                }
                Rectangle {
                    // right
                    color: "#000000"; opacity: 0.4
                    visible: overlay.hasSel
                    x: overlay.selX + overlay.selW; y: overlay.selY
                    width: Math.max(0, parent.width - (overlay.selX + overlay.selW)); height: overlay.selH
                }
                // Selection border
                Rectangle {
                    visible: overlay.hasSel
                    x: overlay.selX; y: overlay.selY
                    width: overlay.selW; height: overlay.selH
                    color: "transparent"
                    border.color: "#ffffff"
                    border.width: 1
                }
            }

            MouseArea {
                id: drag
                anchors.fill: parent
                enabled: overlay.frozen
                hoverEnabled: true
                cursorShape: Qt.CrossCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                focus: true

                property bool active: false
                property int startX: 0
                property int startY: 0
                property int curX: 0
                property int curY: 0

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        root.close();
                        event.accepted = true;
                    }
                }

                onPressed: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        root.close();
                        return;
                    }
                    startX = curX = mouse.x;
                    startY = curY = mouse.y;
                    active = true;
                }
                onPositionChanged: mouse => {
                    if (!active)
                        return;
                    curX = mouse.x;
                    curY = mouse.y;
                }
                onReleased: mouse => {
                    if (mouse.button !== Qt.LeftButton || !active)
                        return;
                    active = false;
                    const w = overlay.selW, h = overlay.selH, x = overlay.selX, y = overlay.selY;
                    if (w < 2 || h < 2) {
                        root.close();
                        return;
                    }
                    const s = overlay.snipScale;
                    const rx = Math.round(x * s), ry = Math.round(y * s);
                    const rw = Math.round(w * s), rh = Math.round(h * s);
                    const crop = "magick " + overlay.tmpPath + " -crop " + rw + "x" + rh + "+" + rx + "+" + ry + " +repage ";
                    let cmd;
                    if (root.savePath && root.savePath.length > 0) {
                        cmd = "mkdir -p '" + root.savePath + "' && "
                            + "f=\"" + root.savePath + "/screenshot-$(date '+%Y-%m-%d_%H.%M.%S').png\" && "
                            + crop + "- | tee \"$f\" | wl-copy; rm -f '" + overlay.tmpPath + "'";
                    } else {
                        cmd = crop + "- | wl-copy; rm -f '" + overlay.tmpPath + "'";
                    }
                    snipProc.command = ["bash", "-c", cmd];
                    snipProc.startDetached();
                    root.close();
                    ToastService.showInfo("Screen Snip", "Region copied to clipboard");
                }
            }
        }
    }
}
