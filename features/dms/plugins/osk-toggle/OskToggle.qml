import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// wvkbd is a plain layer-shell client with no IPC of its own: "toggle" just
// means "is our Process still alive". Killing it externally (or it crashing)
// is picked up by onExited so the bar icon never gets stuck lit.
PluginComponent {
    id: root

    readonly property bool kbdVisible: oskProcess.running

    /*
      Pinned: the keyboard reserves its height the way the bar does (an exclusive
      zone), so windows shrink above it instead of being covered. Floating (the
      default): it hovers over them. wvkbd has no runtime control, so switching
      restarts it -- a brief flicker. Remembered in the plugin's settings.
    */
    property bool pinned: pluginData.pinned === true
    function setPinned(v) {
        pinned = v
        if (pluginService)
            pluginService.savePluginData(pluginId, "pinned", v)
        if (oskProcess.running) {
            oskProcess.running = false
            restart.restart()
        }
    }
    // the old process must have exited before the new one claims the layer
    Timer { id: restart; interval: 150; onTriggered: oskProcess.running = true }

    Process {
        id: oskProcess
        command: [
            "wvkbd-mobintl",
            // Default wvkbd reserves an exclusive zone at its anchor edge,
            // pushing other layout out of the way -- reads as "docked", not
            // floating. That is exactly what pinned wants.
        ].concat(root.pinned ? [] : [
            "--non-exclusive",
            // --width is a local patch (plugins.nix, wvkbdFloating): upstream
            // hardcodes the layer-shell anchor to BOTTOM|LEFT|RIGHT with no
            // way to not span the full output width otherwise. Pinned keeps
            // the full width, like the bar.
            "--width", "1200"
        ]).concat([
            // Default landscape height (120px) is what produced the very
            // flat, wide keys -- 1200/~10 cols vs 320 tall gives a much
            // less squashed per-key aspect ratio.
            "-L", "320",
            "-H", "420",
            "-R", "24",
            // Same 0.65-ish opacity as the rest of the glass system
            // (cursor.nix, qt-theming.nix); actual blur-behind comes from
            // the wvkbd layerrule in wayland/hyprland.nix.
            "--alpha", "170",
            "--bg", "000000"
        ])
        running: false
    }

    function toggle() {
        oskProcess.running = !oskProcess.running
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: "keyboard"
                color: root.kbdVisible ? Theme.primary : Theme.surfaceVariantText
                size: root.iconSize
                anchors.verticalCenter: parent.verticalCenter
            }

            // Pin toggle, shown while the keyboard is up: a touchscreen cannot
            // right-click the pill, so it gets its own target. Filled = pinned.
            DankIcon {
                visible: root.kbdVisible
                name: "push_pin"
                filled: root.pinned
                color: root.pinned ? Theme.primary : Theme.surfaceVariantText
                size: root.iconSize
                anchors.verticalCenter: parent.verticalCenter
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    onClicked: root.setPinned(!root.pinned)
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "keyboard"
                color: root.kbdVisible ? Theme.primary : Theme.surfaceVariantText
                size: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter
            }

            // Pin toggle, shown while the keyboard is up: a touchscreen cannot
            // right-click the pill, so it gets its own target. Filled = pinned.
            DankIcon {
                visible: root.kbdVisible
                name: "push_pin"
                filled: root.pinned
                color: root.pinned ? Theme.primary : Theme.surfaceVariantText
                size: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    onClicked: root.setPinned(!root.pinned)
                }
            }
        }
    }

    pillClickAction: () => toggle()
    pillRightClickAction: () => setPinned(!pinned)
}
