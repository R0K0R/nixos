import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    Process {
        id: grimblastProcess
        command: [
            "grimblast",
            "copy",
            "area"
        ]
        running: false
    }

    function toggle() {
        grimblastProcess.running = !grimblastProcess.running
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
