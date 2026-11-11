// UiBtn.qml
import QtQuick
import SetupUi

// Generic button for the 11-11 design: 124x44, radius 8, 14px Medium label.
//   primary  filled brand teal, white label (下一步 / 安装 / 开始升级 / 重试)
//   default  #fbfbfb fill with a 1px #ececec border, dark label (取消 / 上一步)
//   danger   filled red (not used by the 11-11 screens, kept for the smoke component check)
// Disabled: solid #cccccc fill with a light #eeeeee label (design: "确认并降级" / the license
// "下一步" before the agreement is accepted), not a dimmed copy of the enabled style.
// chevron: "left" / "right" draws the design's ‹ / › next to the label ("上一步" / "下一步").
//
// Kept as a separate file instead of an inline component: this project loads modules through
// absolute qrc paths, and inline components cannot resolve the token table reliably under Qt 6.8
// (see the notes at the top of UiTheme.qml).
Rectangle {
    id: b
    UiTheme { id: theme }   // Plain property object placed after the id (under Qt 6.8 the id must immediately follow the root object)

    property string text: ""
    property bool primary: false
    property bool danger: false
    property bool enabledState: true
    property string chevron: ""
    // Dialog buttons hug their label (padding 32 per side, measured: the 取消 button in the failure
    // dialog is 92px wide while the same label is 124px wide on the wizard pages).
    property bool hug: false
    signal clicked()

    implicitWidth: hug ? content.implicitWidth + 64 : Math.max(theme.btnW, content.implicitWidth + 32)
    implicitHeight: theme.btnH
    radius: theme.radiusBtn
    border.width: (!b.enabledState || b.primary || b.danger) ? 0 : 1
    border.color: theme.btnSecondaryLine
    color: !b.enabledState ? theme.btnDisabled
         : b.danger ? (ma.containsMouse ? theme.dangerInk : theme.danger)
         : b.primary ? (ma.pressed || ma.containsMouse ? theme.brandDark : theme.brand)
         : (ma.pressed ? theme.line : ma.containsMouse ? theme.lineSoft : theme.btnSecondary)
    Behavior on color { ColorAnimation { duration: theme.animFast } }

    readonly property color ink: !b.enabledState ? theme.btnDisabledInk
                                  : (b.primary || b.danger) ? theme.white
                                  : theme.text

    Row {
        id: content
        anchors.centerIn: parent
        height: b.height
        spacing: 6

        // Glyphs are drawn as text so no icon font or image resource is needed; the design uses the
        // same thin ‹ / › chevrons (not a filled triangle).
        // Children of a Row cannot use vertical anchors, so each text is stretched to the button
        // height and centres its glyph itself.
        Text {
            visible: b.chevron === "left"
            width: visible ? implicitWidth : 0
            height: content.height
            verticalAlignment: Text.AlignVCenter
            text: "‹"
            font.family: theme.fontFamily
            font.pixelSize: theme.fontButton + 6
            color: b.ink
        }
        Text {
            id: label
            height: content.height
            verticalAlignment: Text.AlignVCenter
            text: b.text
            font.family: theme.fontFamily
            font.pixelSize: theme.fontButton
            font.weight: Font.Medium
            color: b.ink
        }
        Text {
            visible: b.chevron === "right"
            width: visible ? implicitWidth : 0
            height: content.height
            verticalAlignment: Text.AlignVCenter
            text: "›"
            font.family: theme.fontFamily
            font.pixelSize: theme.fontButton + 6
            color: b.ink
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        enabled: b.enabledState
        cursorShape: b.enabledState ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: b.clicked()
    }
}
