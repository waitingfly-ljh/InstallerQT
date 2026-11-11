// UiCheck.qml
import QtQuick
import SetupUi

// Checkbox row for the 11-11 design: 18px box + 14px label 16px to its right, the whole row is
// clickable. The component is display-only: it never writes `checked` itself, it only emits
// toggled(). The page owns the state (the same pattern the option grid used before), so the box
// stays a pure binding and cannot break the page -> controller chain.
// strong: the design draws the licence-acceptance box with a teal border (#009688) and the option
// grid boxes with a grey one (#6b6b6c); unchecked-only, the checked style is the same teal fill.
Item {
    id: root
    UiTheme { id: theme }

    property string text: ""
    property bool checked: false
    property bool enabledState: true
    property bool strong: false
    signal toggled()

    implicitHeight: 24
    implicitWidth: box.width + theme.checkLabelGap + label.implicitWidth
    opacity: root.enabledState ? 1 : 0.6

    Rectangle {
        id: box
        width: theme.checkSize
        height: theme.checkSize
        radius: 4
        anchors.verticalCenter: parent.verticalCenter
        border.width: root.checked ? 0 : (root.strong ? 2 : 1)
        border.color: root.strong ? theme.checkLineStrong : theme.checkLine
        color: root.checked ? theme.brand : theme.panel
        Text {
            anchors.centerIn: parent
            visible: root.checked
            text: "✓"
            color: theme.white
            font.family: theme.fontFamily
            font.pixelSize: 12
            font.bold: true
        }
    }

    Text {
        id: label
        anchors.left: box.right
        anchors.leftMargin: theme.checkLabelGap
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        // The row may be given a fixed grid width; in that case the label elides instead of
        // running into the neighbouring column.
        width: Math.min(implicitWidth, root.width - box.width - theme.checkLabelGap)
        elide: Text.ElideRight
        font.family: theme.fontFamily
        font.pixelSize: theme.fontBody
        color: theme.text
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.enabledState
        cursorShape: root.enabledState ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.toggled()
    }
}
