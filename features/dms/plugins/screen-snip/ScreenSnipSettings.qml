import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "screenSnip"

    StyledText {
        width: parent.width
        text: "Screen Snip"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Drag a region to copy it to the clipboard. Drawn as an in-shell overlay so the S Pen works (slurp, which hyprshot uses, ignores tablet input). Bound to Print; Esc or right-click cancels."
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
        settingKey: "savePath"
        label: "Save directory"
        description: "Also write each snip here as a PNG. Leave empty to only copy to the clipboard."
        placeholder: "e.g. ~/Pictures/Screenshots"
        defaultValue: ""
    }
}
