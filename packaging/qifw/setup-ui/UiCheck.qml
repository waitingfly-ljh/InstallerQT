// UiCheck.qml
import QtQuick
import SetupUi

// Checkbox row for the 11-11 design: a 17px box with 4.5px corners (16px / 4px for the emphasised
// licence-acceptance variant) and a 13px label 16px to its right, the whole row is clickable.
// Measured: option grid boxes are 17x17 rx4.5 with a 1px #6B6B6C ring; the licence box is 16x16
// rx4 with a 2px #009688 ring. Checked: brand fill with a white tick and no ring.
// The component is display-only: it never writes `checked` itself, it only emits toggled(). The page
// owns the state (the same pattern the option grid used before), so the box stays a pure binding and
// cannot break the page -> controller chain.
// Disabled: the row keeps full opacity; only the ring and the label are demoted (measured frames
// show the disabled box still at 1px ink), so it is not a 60% ghost of the enabled style.
Item {
    id: root
    UiTheme { id: theme }

    property string text: ""
    property bool checked: false
    property bool enabledState: true
    property bool strong: false
    // 0 = the shared 13px body size; the option grid sets 14 (measured em≈14 on 安装设置) while the
    // licence acceptance keeps 13 (measured em≈13 on 许可协议).
    property int labelSize: 0
    signal toggled()

    readonly property int boxSize: root.strong ? theme.checkSizeStrong : theme.checkSize
    readonly property real boxRadius: root.strong ? theme.radiusCheckStrong : theme.radiusCheck

    implicitHeight: 24
    implicitWidth: boxSize + theme.checkLabelGap + label.implicitWidth

    Rectangle {
        id: box
        width: root.boxSize
        height: root.boxSize
        radius: root.boxRadius
        anchors.verticalCenter: parent.verticalCenter
        border.width: root.checked ? 0 : (root.strong ? 2 : 1)
        border.color: !root.enabledState ? theme.mutedSoft
                    : root.checked ? theme.brand
                    : hover.hovered ? theme.brand
                    : (root.strong ? theme.checkLineStrong : theme.checkLine)
        color: root.checked ? theme.brand : theme.panel
        Behavior on border.color { ColorAnimation { duration: theme.animFast } }
        Text {
            anchors.centerIn: parent
            visible: root.checked
            text: "✓"
            color: theme.white
            font.family: theme.fontFamily
            font.pixelSize: theme.fontCheck
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
        font.pixelSize: root.labelSize > 0 ? root.labelSize : theme.fontBody
        color: root.enabledState ? theme.text : theme.mutedSoft
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabledState
        cursorShape: root.enabledState ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.toggled()
    }
}
