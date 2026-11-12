// UiNoteCard.qml
import QtQuick
import SetupUi

// The 80px tinted note card used by the uninstall screens:
//   确认卸载  140..219 (#fff7e9, #f0d5a3 border) and 236..315 (#f2f9f9, brand border)
//   卸载完成  313..392 (#f2f9f9, brand border)
// Measured inside: 14px left padding, 16px title with its ink at +19, 12px body with its ink at +50.
// Text is laid out in fixed-height rows so the ink lands on those rows instead of following the
// font metrics of each platform.
//
// The design's body copy is Chinese and fits on one line, so the card is 80px tall. The English
// copy is much longer and needs two lines; instead of eliding it the card grows by exactly one
// line (80 -> ~97) and keeps the same 17px bottom padding, so the 80px frame is still what a
// one-line body gets. Callers should therefore not pin the height.
Rectangle {
    id: card
    UiTheme { id: theme }

    property string title: ""
    property string body: ""
    // true = warning wash (what the uninstall clears), false = informational teal wash.
    property bool warn: false

    // 45 (body row) + the laid-out body + the design's 17px bottom padding, never below 80.
    implicitHeight: Math.max(80, bodyBox.y + bodyLabel.contentHeight + 17)
    radius: theme.radiusCard
    color: card.warn ? theme.cardWarn : theme.cardTeal
    border.width: 1
    border.color: card.warn ? theme.cardWarnLine : theme.brand

    Item {
        x: 14
        y: 17
        width: parent.width - 28
        height: 20
        Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            text: card.title
            elide: Text.ElideRight
            font.family: theme.fontFamily
            font.pixelSize: theme.fontCardInk
            font.weight: Font.DemiBold
            color: theme.text
        }
    }
    Item {
        id: bodyBox
        x: 14
        y: 45
        width: parent.width - 28
        height: Math.max(16, bodyLabel.contentHeight)
        Text {
            id: bodyLabel
            anchors.left: parent.left
            anchors.right: parent.right
            y: 0
            verticalAlignment: Text.AlignTop
            text: card.body
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            font.family: theme.fontFamily
            font.pixelSize: theme.fontBody
            color: theme.cardBody
        }
    }
}
