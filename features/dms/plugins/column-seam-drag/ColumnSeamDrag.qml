import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Common
import qs.Services
import qs.Modules.Plugins

/*
  Drag the seam between two adjacent columns to resize BOTH at once -- one
  grows by exactly what the other loses, total constant, like a tiling divider.

  This is only the CENTRE band of the seam. Either side of it, Hyprland's own
  resize_on_border does the one-sided resizes (features/hyprland widens
  extend_border_grab_area to 32 for exactly that), which also gets the proper
  directional w-/e-resize cursor -- something a client cannot ask for. Splitting
  it this way keeps this strip narrow, so it stops sitting on top of shell
  surfaces, and leaves the compositor doing what it already does well.

  What it does that native cannot: the conserved drag (native resizes one
  window and lets the tape absorb the difference), and the S Pen -- each handle
  is a Quickshell (qtwayland) window, which receives tablet events and
  synthesizes a mouse press from the tip, whereas Hyprland routes a tablet tip
  only through the tablet protocol, never as a pointer button, so the pen
  cannot drive the native border path at all.

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

    // The handle is ONLY the centre band now. The one-sided resizes are
    // Hyprland's job: features/hyprland widens extend_border_grab_area to 32,
    // so the native hitbox either side of the seam resizes the single window
    // whose border you caught -- and shows the proper directional w-/e-resize
    // cursor, which a client cannot request. This strip does the one thing
    // native cannot: the CONSERVED drag, both columns at once.
    //
    // Staying narrow is also what keeps it from obscuring shell surfaces: it
    // is a thin line down the seam rather than a full-width band over the
    // window edges.
    readonly property int handleW: 12

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
                y: io.y,
                // Logical width, from the same IPC data as every other
                // coordinate here. ShellScreen.width/devicePixelRatio is NOT
                // usable for this: it came back undefined, so the viewport
                // bound went NaN and the visibility filter rejected every
                // column (no handles at all).
                logicalW: io.width / (io.scale || 1),
                logicalH: io.height / (io.scale || 1),
                // reserved = [left, top, right, bottom]: the exclusive zones
                // the shell has claimed (the bar's 42px here). Handles stay
                // out of them so they never sit on top of shell surfaces.
                resTop: (io.reserved && io.reserved[1]) || 0,
                resBottom: (io.reserved && io.reserved[3]) || 0
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

            // Only columns with a real slice ON SCREEN can own a seam. Without
            // this, maximising one column (Mod+D, colresize to fill) left a
            // handle at the screen edge: the neighbour is still on the
            // workspace, merely scrolled out of view, and it still counted as
            // adjacent. A sliver a few pixels wide is not something you can
            // drag against either, hence a minimum rather than "> 0".
            const visLo = m.x, visHi = m.x + m.logicalW;
            const onScreen = c => Math.min(c.right, visHi) - Math.max(c.left, visLo) >= 100;
            const visible = colInfo.filter(onScreen);
            if (visible.length < 2)
                continue;

            for (let i = 0; i + 1 < visible.length; i++) {
                const a = visible[i], b = visible[i + 1];
                // Adjacent only: the gap between them is small.
                if (b.left - a.right > 24)
                    continue;
                const seamGlobalX = (a.right + b.left) / 2;
                // Clamp to the monitor's unreserved band so a handle can never
                // overlap the bar (or any other exclusive-zone shell surface).
                const safeTop = m.y + m.resTop;
                const safeBot = m.y + m.logicalH - m.resBottom;
                const top = Math.max(Math.max(a.top, b.top), safeTop);
                const bot = Math.min(Math.min(a.bot, b.bot), safeBot);
                if (bot - top < 40)
                    continue;
                out.push({
                    screen: scr,
                    monW: m.logicalW,
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

    // Smallest a column may be driven to, 10% of the monitor. Uses the logical
    // width carried on the seam (from Hyprland's IPC), NOT
    // ShellScreen.width/devicePixelRatio -- that came back undefined here and
    // would make every clamp NaN.
    function minW(s) {
        return Math.round((s.monW || 1920) * 0.1);
    }

    // CONSERVED drag: the seam moves, one column grows by exactly what the
    // other loses, total constant -- a tiling divider, which the scrolling
    // layout has no notion of. dx is the total drag from the press point, so
    // widths are set absolutely from their grab-time values: live, no drift.
    function applyDrag(s, dx) {
        const total = s.leftW + s.rightW;
        const lw = Math.max(minW(s), Math.min(s.leftW + dx, total - minW(s)));
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
    }

    /*
      Geometry comes from each toplevel's lastIpcObject, and Quickshell only
      refills those when someone asks -- Hyprland.refreshToplevels(). Without
      the refresh the handle was computed once and then never moved again: it
      sat at a stale seam while columns resized underneath it, which is what
      made it look like it "appears even when one window is maximised".
      So: ask for fresh data, then recompute a beat later once the reply has
      landed (refresh is asynchronous -- recomputing in the same tick just
      re-reads the old values).
    */
    function resync() {
        if (dragging)
            return;
        Hyprland.refreshToplevels();
        Hyprland.refreshMonitors();
        settle.restart();
    }

    Timer {
        id: settle
        interval: 120
        repeat: false
        onTriggered: root.recompute()
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            root.resync();
        }
    }
    Connections {
        target: CompositorService
        function onToplevelsChanged() {
            root.resync();
        }
    }
    // Fallback resync: catches the first paint, and anything the events miss.
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.resync()
    }
    Component.onCompleted: resync()

    Variants {
        model: root.seams

        PanelWindow {
            id: handle
            required property var modelData
            screen: modelData.screen

            WlrLayershell.namespace: "seamdrag"
            // TOP, not Overlay: still above ordinary windows (which is all a
            // resize handle needs), but below everything the shell puts on the
            // Overlay layer -- popouts, tooltips, OSD, toasts. As an Overlay
            // surface this full-height strip swallowed touches aimed at those,
            // e.g. the media/music popout.
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.exclusionMode: ExclusionMode.Ignore

            anchors { left: true; top: true }
            margins.left: Math.round(modelData.localX - root.handleW / 2)
            margins.top: Math.round(modelData.localTop)
            implicitWidth: root.handleW
            implicitHeight: Math.round(modelData.height)
            color: "transparent"

            // A faint line marking the seam, on hover only; invisible while
            // dragging and at rest so it never clutters the screen.
            Rectangle {
                anchors.centerIn: parent
                width: 2
                height: parent.height
                radius: 1
                color: "#ffffff"
                opacity: area.pressed ? 0.0 : (area.containsMouse ? 0.3 : 0.0)
                Behavior on opacity { NumberAnimation { duration: 120 } }
            }

            MouseArea {
                id: area
                anchors.fill: parent
                hoverEnabled: true
                // Always the both-columns divider: the one-sided resizes are
                // Hyprland's native border grab either side of this strip, and
                // it draws its own directional cursor there.
                cursorShape: Qt.SizeHorCursor
                acceptedButtons: Qt.LeftButton
                preventStealing: true

                property real pressX: 0

                onPressed: mouse => {
                    pressX = mouse.x;
                    root.dragging = true; // freeze the model for the drag
                }
                onPositionChanged: mouse => {
                    if (!pressed)
                        return;
                    root.applyDrag(handle.modelData, Math.round(mouse.x - pressX));
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
