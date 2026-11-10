// StepList.qml
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

// Left step list: numbered dot + text, three states (active / done / pending).
// The state is passed in externally via the model's "state" field: active | done | pending.
// All three states are shown on the dark sidebar, so active uses the bright brand color (brandAccent) rather than
// brandDark used for light backgrounds — the latter is nearly invisible as a highlight on sideTop.
//
// Colors and font sizes come from this file's UiTheme instance (see the notes at the top of UiTheme.qml).
Column {
    id: root
    UiTheme { id: theme }   // Visual token instance, see the notes at the top of UiTheme.qml
    spacing: 20                  // Design mockup .step-list { gap: 20px }

    property var steps: []       // [{ "label": "Install options", "state": "active" }, ...]
    readonly property color activeDotSoft: theme.sideActiveDot      // .step-item.active .step-dot background
    readonly property color activeDotRing: theme.sideActiveRing
    readonly property color activeDotInk: theme.sideActiveRing
    readonly property color activeText: theme.white
    readonly property color pendingInk: theme.sidePendingInk
    readonly property color doneDot: theme.sideDoneDot
    readonly property color doneDotRing: theme.sideDoneRing
    readonly property color doneInk: theme.sideDoneInk
    readonly property string family: theme.fontFamily
    readonly property int bodySize: theme.fontBody
    readonly property int smallSize: theme.fontFoot        // number 11px

    Repeater {
        model: root.steps
        delegate: Item {
            id: row
            required property int index
            required property var modelData
            width: root.width
            height: 24                  // same height as the dot (.step-dot 24px); row gap comes from spacing
            readonly property string state: modelData.state || "pending"

            Rectangle {
                id: dot
                width: 24; height: 24
                radius: 12
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                border.width: 1
                border.color: row.state === "active" ? root.activeDotRing
                            : row.state === "done" ? root.doneDotRing
                            : theme.sideRing
                color: row.state === "active" ? root.activeDotSoft
                     : row.state === "done" ? root.doneDot
                     : "transparent"

                Text {
                    anchors.centerIn: parent
                    text: row.state === "done" ? "✓" : String(row.index + 1)
                    // In the design mockup the number inside an active dot is white (on the brand-colored background); the check mark reuses the done stroke color.
                    color: row.state === "active" ? theme.white
                         : row.state === "done" ? root.doneDotRing
                         : root.pendingInk
                    font.family: root.family
                    font.pixelSize: root.smallSize
                    font.bold: row.state === "active"
                }
            }

            Text {
                anchors.left: dot.right
                anchors.leftMargin: 4          // .step-item: grid-template-columns 28px -> gap 4px
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.label
                color: row.state === "active" ? root.activeText
                     : row.state === "done" ? root.doneInk
                     : root.pendingInk
                font.family: root.family
                font.pixelSize: root.bodySize
                font.bold: row.state === "active"
            }

            MouseArea {
                anchors.fill: parent
                enabled: row.state === "done"
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.stepClicked(row.index)
            }
        }
    }
    signal stepClicked(int index)
}
