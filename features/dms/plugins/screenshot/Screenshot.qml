import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // hyprshot, not grimblast: grimblast's `area` always runs slurp in
    // snap-to-window mode (`slurp -o` with window rects on stdin) and that mode
    // does not accept touch input. hyprshot's region mode is a plain `slurp -d`,
    // which does. See the comment in features/hyprland/home.nix for the full
    // measurement -- including the S Pen, which works in neither.
    Process {
        id: screenshotProcess
        command: [
            "hyprshot",
            "-m", "region",
            "--clipboard-only",
            "--silent"
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
