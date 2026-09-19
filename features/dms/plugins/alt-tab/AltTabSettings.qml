import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "altTab"

    StyledText {
        width: parent.width
        text: "Alt-Tab"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Open Hyprland windows with live previews, most recently used first: the focused window, then the one before it. Alt+Tab opens it; arrows move, Enter focuses."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StringSetting {
        settingKey: "trigger"
        label: "Trigger"
        description: "Launcher prefix that lists windows (default: !)"
        placeholder: "!"
        defaultValue: "!"
    }
}
