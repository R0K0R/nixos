import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Common
import qs.Services
import qs.Modules.Plugins

/*
  Drag the seam between two adjacent columns to resize both at once -- the one
  you drag from shrinks by exactly what its neighbour grows, total constant,
  like a tiling divider. Works with mouse, finger, AND the S Pen: each handle
  is a Quickshell (qtwayland) window, which receives tablet events and
  synthesizes a mouse press from the tip, so the pen drives it like a click --
  unlike Hyprland's native resize_on_border, which the tablet tip cannot reach
  (it is routed only through the tablet protocol, never as a pointer button).

  The scrolling layout is not tiling: resizing one column feeds the freed space
  to the scroll offset and leaves the neighbour alone. So each drag sets BOTH
  columns to EXACT target widths whose sum is unchanged (exact widths are
  idempotent and land precisely; relative deltas drift because the layout
  re-fits after each). Same primitive as features/hyprland/column-resize-split.py
  behind Super+;/'.

  STRUCTURE. One small Overlay-layer window PER SEAM (not one masked
  full-screen overlay -- a Region mask cannot be a dynamic union of N handles).
  Each window is the grab handle, so everything off a handle is click-through by
  construction. The seam list is recomputed from Hyprland's toplevels whenever
  the layout changes, EXCEPT during an active drag -- otherwise a live resize
  would rebuild the Variants model and destroy the very window being dragged.
*/
PluginComponent {
    id: root

    property var popoutService: null

    // Handle width (px) and the width of its central "both" band. Narrow now:
    // the left/right thirds resize a single column, which is exactly what
    // Hyprland's native resize_on_border does just beyond the handle, so the
    // two agree and the handle no longer needs to out-reach the 15px native
    // zone. The pen still needs the handle (native ignores the tablet). Centre
    // band kept small so the two single-column zones are the easy target.
    readonly property int handleW: 22
    readonly property int centerW: 8

    // Frozen while a drag is in flight so the model does not rebuild under it.
    property bool dragging: false
    property var seams: []

    function screenFor(name) {
        for (const s of Quickshell.screens) {
            if (s.name === name)
                return s;
        }
        return null;
    }

    // Recompute the seams: for each monitor's active workspace, group tiled
    // mapped toplevels into columns by x, and put a handle between adjacent
    // columns that actually touch.
    function recompute() {
        if (dragging)
            return;
        if (!CompositorService.isHyprland || !Hyprland.toplevels || !Hyprland.monitors) {
            seams = [];
            return;
        }

        // monitor id -> {name, activeWs, x, y}
        const mons = {};
        for (const m of Hyprland.monitors.values) {
            const io = m.lastIpcObject;
            if (!io)
                continue;
            mons[io.id] = {
                name: io.name,
                ws: io.activeWorkspace ? io.activeWorkspace.id : -1,
                x: io.x,
                y: io.y
            };
        }

        // Bucket windows by monitor, then by column x.
        const byMon = {};
        for (const t of Hyprland.toplevels.values) {
            const io = t.lastIpcObject;
            if (!io || !io.mapped || io.hidden || io.floating)
                continue;
            const m = mons[io.monitor];
            if (!m || !io.workspace || io.workspace.id !== m.ws)
                continue;
            if (io.size[0] <= 0)
                continue;
            (byMon[io.monitor] = byMon[io.monitor] || []).push(io);
        }

        const out = [];
        for (const monId in byMon) {
            const m = mons[monId];
            const scr = screenFor(m.name);
            if (!scr)
                continue;

            // Columns keyed by rounded x.
            const cols = {};
            for (const io of byMon[monId]) {
                const key = Math.round(io.at[0] / 8) * 8;
                (cols[key] = cols[key] || []).push(io);
            }
            const keys = Object.keys(cols).map(Number).sort((a, b) => a - b);
            if (keys.length < 2)
                continue;

            const colInfo = keys.map(k => {
                const ws = cols[k];
                const left = Math.min(...ws.map(w => w.at[0]));
                const right = Math.max(...ws.map(w => w.at[0] + w.size[0]));
                const top = Math.min(...ws.map(w => w.at[1]));
                const bot = Math.max(...ws.map(w => w.at[1] + w.size[1]));
                // Representative window carries the column width/height.
                const rep = ws[0];
                return { left, right, top, bot, addr: rep.address, w: rep.size[0], h: rep.size[1] };
            });

            for (let i = 0; i + 1 < colInfo.length; i++) {
                const a = colInfo[i], b = colInfo[i + 1];
                // Adjacent only: the gap between them is small.
                if (b.left - a.right > 24)
                    continue;
                const seamGlobalX = (a.right + b.left) / 2;
                const top = Math.max(a.top, b.top);
                const bot = Math.min(a.bot, b.bot);
                if (bot - top < 40)
                    continue;
                out.push({
                    screen: scr,
                    localX: seamGlobalX - m.x,
                    localTop: top - m.y,
                    height: bot - top,
                    leftAddr: a.addr, leftW: a.w, leftH: a.h,
                    rightAddr: b.addr, rightW: b.w, rightH: b.h
                });
            }
        }
        seams = out;
    }

    function setW(addr, w, h) {
        Hyprland.dispatch('hl.dsp.window.resize({ x = ' + Math.round(w) + ', y = ' + Math.round(h)
            + ', relative = false, window = "address:' + addr + '" })');
    }

    function minW(s) {
        return Math.round(s.screen.width / s.screen.devicePixelRatio * 0.1);
    }

    // THREE ZONES, chosen at grab time from where on the handle you press:
    //   centre third -> conserved, both columns (a tiling divider);
    //   left third   -> resize the LEFT column only (right keeps its width,
    //                   the tape takes up the slack -- normal scrolling);
    //   right third  -> resize the RIGHT column only.
    // In every zone dragging right moves the seam right; the zone only decides
    // which column(s) absorb it. dx is the total drag from the press point, so
    // widths are set absolutely from their grab-time values -- live, no drift.

    // zone: -1 left-only, 0 both, 1 right-only
    function applyDrag(s, dx, zone) {
        if (zone === 0) {
            const total = s.leftW + s.rightW;
            let lw = Math.max(minW(s), Math.min(s.leftW + dx, total - minW(s)));
            const rw = total - lw;
            // Shrink side first so no intermediate state overflows the usable
            // width (which would trip the layout's fit-to-width scaling).
            if (dx > 0) {
                setW(s.rightAddr, rw, s.rightH);
                setW(s.leftAddr, lw, s.leftH);
            } else {
                setW(s.leftAddr, lw, s.leftH);
                setW(s.rightAddr, rw, s.rightH);
            }
        } else if (zone < 0) {
            // Left column only. Growing it past the screen is fine -- the tape
            // just scrolls, which is what the scrolling layout is for.
            setW(s.leftAddr, Math.max(minW(s), s.leftW + dx), s.leftH);
        } else {
            // Right column only. Seam right = right's left edge right = shrink.
            setW(s.rightAddr, Math.max(minW(s), s.rightW - dx), s.rightH);
        }
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            root.recompute();
        }
    }
    Connections {
        target: CompositorService
        function onToplevelsChanged() {
            root.recompute();
        }
    }
    // Fallback resync (e.g. first paint before any event).
    Timer {
        interval: 1500
        running: true
        repeat: true
        onTriggered: root.recompute()
    }
    Component.onCompleted: recompute()

    Variants {
        model: root.seams

        PanelWindow {
            id: handle
            required property var modelData
            screen: modelData.screen

            WlrLayershell.namespace: "seamdrag"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.exclusionMode: ExclusionMode.Ignore

            anchors { left: true; top: true }
            margins.left: Math.round(modelData.localX - root.handleW / 2)
            margins.top: Math.round(modelData.localTop)
            implicitWidth: root.handleW
            implicitHeight: Math.round(modelData.height)
            color: "transparent"

            // Centre seam line, plus a faint highlight over the third under the
            // cursor so the three zones are discoverable. All invisible while
            // dragging (per request) and at rest.
            Rectangle {
                anchors.centerIn: parent
                width: 2
                height: parent.height
                radius: 1
                color: "#ffffff"
                opacity: area.pressed ? 0.0 : (area.containsMouse ? 0.3 : 0.0)
                Behavior on opacity { NumberAnimation { duration: 120 } }
            }
            Rectangle {
                // Which third the cursor is over: left | centre | right.
                visible: area.containsMouse && !area.pressed
                height: parent.height
                color: "#ffffff"
                opacity: 0.12
                property real lo: (parent.width - root.centerW) / 2
                x: area.hoverX < lo ? 0 : (area.hoverX > parent.width - lo ? parent.width - lo : lo)
                width: area.hoverX < lo ? lo : (area.hoverX > parent.width - lo ? lo : root.centerW)
            }

            MouseArea {
                id: area
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.SizeHorCursor
                acceptedButtons: Qt.LeftButton
                preventStealing: true

                property real pressX: 0
                property real hoverX: 0
                property int zone: 0 // -1 left-only, 0 both, 1 right-only

                function zoneAt(x) {
                    const lo = (width - root.centerW) / 2;
                    return x < lo ? -1 : (x > width - lo ? 1 : 0);
                }

                onPositionChanged: mouse => {
                    if (pressed) {
                        // Live: apply the grab-time zone on every move.
                        root.applyDrag(handle.modelData, Math.round(mouse.x - pressX), zone);
                    } else {
                        hoverX = mouse.x;
                    }
                }
                onPressed: mouse => {
                    pressX = mouse.x;
                    zone = zoneAt(mouse.x); // lock the zone for the whole drag
                    root.dragging = true; // freeze the model for the drag
                }
                onReleased: mouse => {
                    root.dragging = false;
                    root.recompute();
                }
                onCanceled: {
                    root.dragging = false;
                    root.recompute();
                }
            }
        }
    }
}
