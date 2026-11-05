// Brand mark: green rounded square + inset light square (corresponds to design mockup .brand-mark and ::after).
import QtQuick

Item {
    id: root
    UiTheme { id: theme }   // Visual token instance, see the notes at the top of UiTheme.qml
    // Colors default to the brand color; callers may override.
    property color base: theme.brand
    property color accent: theme.brandSoft
    implicitWidth: 14
    implicitHeight: 14

    Rectangle {
        anchors.fill: parent
        radius: 3
        color: root.base
    }
    Rectangle {
        width: Math.round(root.width * 0.42)
        height: width
        radius: Math.round(width * 0.3)
        anchors.centerIn: parent
        color: root.accent
    }
}
