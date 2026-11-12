// UiRadio.qml
import QtQuick
import SetupUi

// Circular radio for the 11-11 design. Two measured sizes:
//   compact = false  snapshot page  d25 ring + d18 brand dot  (创建快照 frame, cx 512 cy 423)
//   compact = true   uninstall page d19 ring + d14 brand dot  (卸载 frame, r 9.4)
// States: unselected (#6B6B6C 1px ring), selected (brand ring + brand dot), hover (brand ring),
// disabled (muted ring, grey label). The ring box never moves between states: only the dot appears.
// Display-only like UiCheck: it emits toggled(), the page/controller owns the state.
Item {
    id: root
    UiTheme { id: theme }

    property bool checked: false
    property bool compact: false
    property bool enabledState: true
    property string text: ""
    signal toggled()

    readonly property int ring: root.compact ? theme.radioSizeSm : theme.radioSizeLg
    readonly property int dot: root.compact ? theme.radioDotSm : theme.radioDotLg

    implicitWidth: root.ring + (root.text.length > 0 ? theme.radioLabelGap + label.implicitWidth : 0)
    implicitHeight: Math.max(root.ring, 24)

    Rectangle {
        id: ringRect
        width: root.ring
        height: root.ring
        radius: root.ring / 2
        anchors.verticalCenter: parent.verticalCenter
        color: "transparent"
        border.width: 1
        border.color: !root.enabledState ? theme.mutedSoft
                    : (root.checked || hover.hovered) ? theme.brand
                    : theme.radioRing
        Behavior on border.color { ColorAnimation { duration: theme.animFast } }

        Rectangle {
            anchors.centerIn: parent
            visible: root.checked
            width: root.dot
            height: root.dot
            radius: root.dot / 2
            color: root.enabledState ? theme.brand : theme.mutedSoft
        }
    }

    Text {
        id: label
        visible: root.text.length > 0
        anchors.left: ringRect.right
        anchors.leftMargin: theme.radioLabelGap
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        font.family: theme.fontFamily
        font.pixelSize: theme.fontBody
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
