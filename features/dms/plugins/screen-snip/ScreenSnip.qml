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
  slurp 1.5.0's registry -- no tablet symbols at all). Hyprland 0.56 routes
  an S Pen tip ONLY through the tablet protocol (Tablets.cpp onTabletTip ->
  PROTO::tablet->down, no pointer-button emulation), so the pen moves the
  cursor over slurp but a tap/drag reaches it as nothing. No compositor or
  slurp option bridges it; touch works only because Hyprland emulates
  pointer for touch, not for tablets.

  A Quickshell window is a qtwayland client: it DOES bind the tablet
  protocol, and Qt synthesizes a mouse press from an unhandled tablet tip
  (AA_SynthesizeMouseForUnhandledTabletEvents, on by default), which a
  MouseArea handles like any click. So the pen just works here. Same idea
  as end-4/dots-hyprland's screenSnip.

  MECHANISM. Selection happens over the LIVE screen, exactly like slurp --
  no frozen capture, so the overlay appears instantly and there is no
  full-screen grab to wait on. One Overlay-layer PanelWindow per screen
  maps transparent with a dark dimming everywhere except the selection.
  `exclusionMode: Ignore` is essential: without it the bar's exclusive
  zone shrinks the overlay to below the bar. On release the dimming is
  hidden (so the window is fully transparent and does not alter the
  output), then `grim -g` grabs just the chosen region -- in global LOGICAL
  layout coordinates, which is grim's geometry space, so no manual scaling
  -- and pipes it to wl-copy. Esc or right-click cancels.

  Bound in features/hyprland/home.nix (Print) and reachable as
  `dms ipc call screenSnip region`; the bar's Screenshot widget calls the
  same IPC. hyprshot stays wired as the fallback for when the shell is
  down.
*/
PluginComponent {
    id: root

    property bool active: false
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

    Variants {
        model: root.active ? Quickshell.screens : []

        PanelWindow {
            id: overlay

            required property var modelData
            screen: modelData

            // Selection is captured while the window is transparent, so grim
            // sees the real screen. Flag flips off the dimming just before the
            // grab so nothing of ours is in the shot.
            property bool capturing: false

            WlrLayershell.namespace: "dms-screensnip"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            // Ignore the bar's exclusive zone; cover the ENTIRE output. Without
            // this the overlay is pushed under the bar and every coordinate is
            // off by the bar height. Both are ATTACHED WlrLayershell properties
            // -- unqualified `exclusionMode` is silently ignored.
            WlrLayershell.exclusionMode: ExclusionMode.Ignore

            anchors {
                left: true
                right: true
                top: true
                bottom: true
            }
            color: "transparent"

            Process { id: snipProc }

            Timer {
                id: captureTimer
                interval: 40 // one or two frames for the dimming to clear
                repeat: false
                onTriggered: {
                    const s = overlay.modelData;
                    const gx = Math.round(s.x + overlay.selX);
                    const gy = Math.round(s.y + overlay.selY);
                    const gw = Math.round(overlay.selW);
                    const gh = Math.round(overlay.selH);
                    const geom = gx + "," + gy + " " + gw + "x" + gh;
                    let cmd;
                    if (root.savePath && root.savePath.length > 0) {
                        cmd = "mkdir -p '" + root.savePath + "' && "
                            + "f=\"" + root.savePath + "/screenshot-$(date '+%Y-%m-%d_%H.%M.%S').png\" && "
                            + "grim -g '" + geom + "' - | tee \"$f\" | wl-copy";
                    } else {
                        cmd = "grim -g '" + geom + "' - | wl-copy";
                    }
                    snipProc.command = ["bash", "-c", cmd];
                    snipProc.startDetached();
                    ToastService.showInfo("Screen Snip", "Region copied to clipboard");
                    root.close();
                }
            }

            readonly property int selX: Math.min(drag.startX, drag.curX)
            readonly property int selY: Math.min(drag.startY, drag.curY)
            readonly property int selW: Math.abs(drag.curX - drag.startX)
            readonly property int selH: Math.abs(drag.curY - drag.startY)
            readonly property bool hasSel: drag.active && selW > 0 && selH > 0

            // Four dim panels around the selection; the selection stays clear.
            // Hidden entirely while capturing so grim gets a clean frame.
            Item {
                anchors.fill: parent
                visible: !overlay.capturing
                Rectangle {
                    color: "#000000"; opacity: 0.35
                    x: 0; y: 0; width: parent.width
                    height: overlay.hasSel ? overlay.selY : parent.height
                }
                Rectangle {
                    color: "#000000"; opacity: 0.35
                    visible: overlay.hasSel
                    x: 0; y: overlay.selY + overlay.selH
                    width: parent.width; height: Math.max(0, parent.height - (overlay.selY + overlay.selH))
                }
                Rectangle {
                    color: "#000000"; opacity: 0.35
                    visible: overlay.hasSel
                    x: 0; y: overlay.selY
                    width: overlay.selX; height: overlay.selH
                }
                Rectangle {
                    color: "#000000"; opacity: 0.35
                    visible: overlay.hasSel
                    x: overlay.selX + overlay.selW; y: overlay.selY
                    width: Math.max(0, parent.width - (overlay.selX + overlay.selW)); height: overlay.selH
                }
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
                enabled: !overlay.capturing
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
                    if (overlay.selW < 2 || overlay.selH < 2) {
                        root.close();
                        return;
                    }
                    overlay.capturing = true; // drop the dimming, then grab
                    captureTimer.restart();
                }
            }
        }
    }
}
