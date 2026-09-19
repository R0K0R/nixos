import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "columnSeamDrag"

    StyledText {
        width: parent.width
        text: "Column Seam Drag"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Drag the seam between two side-by-side columns to resize both at once: one shrinks by exactly what the other grows, like a tiling divider. Works with mouse, finger, and the S Pen. The grab strip is a few pixels wider than the visible line so it is easy to catch."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
