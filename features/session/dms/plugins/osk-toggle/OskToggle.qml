import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Bar pill for the on-screen keyboard. The keyboard itself is the oskKeyboard
// daemon plugin (features/dms/plugins/osk-keyboard: QML, replaced wvkbd for pen
// support, a Super key and the look); this pill shows and hides it and toggles
// pin, through the daemon instance DMS keeps in pluginDaemonInstances -- one
// keyboard however many bars carry a pill.
PluginComponent {
    id: root

    readonly property var osk: pluginService && pluginService.pluginDaemonInstances
        ? (pluginService.pluginDaemonInstances["oskKeyboard"] || null) : null
    readonly property bool kbdVisible: osk ? osk.shown : false
    // Pinned: the keyboard reserves its height like the bar, windows shrink above
    // it. Floating: it hovers over them. The state lives in the keyboard plugin.
    readonly property bool pinned: osk ? osk.pinned : false
    function setPinned(v) { if (osk) osk.setPinned(v) }
    function toggle() {
        if (osk) osk.toggle()
        else Quickshell.execDetached(["dms", "ipc", "call", "osk", "toggle"])   // instance not resolved
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
