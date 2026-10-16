import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // Region snip via the screenSnip plugin's in-shell overlay, which the
    // S Pen can drive; slurp (hyprshot's region backend) ignores tablet
    // input. Same IPC the Print keybind uses; hyprshot stays only as the
    // compositor-side fallback for when the shell is down.
    Process {
        id: screenshotProcess
        command: [
            "dms", "ipc", "call", "screenSnip", "region"
        ]
        running: false
    }

    function toggle() {
        screenshotProcess.running = !screenshotProcess.running
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: "camera"
                color: Theme.primary
                size: root.iconSize
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "camera"
                color: Theme.primary
                size: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    pillClickAction: () => toggle()
}
