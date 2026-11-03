// StepList.qml
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

// 左侧步骤列表：序号圆点 + 文本，三种状态（active / done / pending）。
// 状态由外部通过 model 的 "state" 字段传入：active | done | pending。
// 三种状态固定在深色侧栏上显示，所以 activity 用亮品牌色（brandAccent）而不是
// 浅背景用的 brandDark——后者在 sideTop 上几乎看不出高亮。
//
// 配色与字号来自本文件的 UiTheme 实例（见 UiTheme.qml 顶部说明）。
Column {
    id: root
    UiTheme { id: theme }   // 视觉令牌实例，见 UiTheme.qml 顶部说明
    spacing: 20                  // 评审稿 .step-list { gap: 20px }

    property var steps: []       // [{ "label": "安装设置", "state": "active" }, ...]
    readonly property color activeDotSoft: theme.sideActiveDot      // .step-item.active .step-dot 底
    readonly property color activeDotRing: theme.sideActiveRing
    readonly property color activeDotInk: theme.sideActiveRing
    readonly property color activeText: theme.white
    readonly property color pendingInk: theme.sidePendingInk
    readonly property color doneDot: theme.sideDoneDot
    readonly property color doneDotRing: theme.sideDoneRing
    readonly property color doneInk: theme.sideDoneInk
    readonly property string family: theme.fontFamily
    readonly property int bodySize: theme.fontBody
    readonly property int smallSize: theme.fontFoot        // 序号 11px

    Repeater {
        model: root.steps
        delegate: Item {
            id: row
            required property int index
            required property var modelData
            width: root.width
            height: 24                  // 与圆点同高（.step-dot 24px），行距由 spacing 给
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
                    // 评审稿 active 圆点里的序号是白字（品牌色底上）；对勾沿用 done 描边色。
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
                anchors.leftMargin: 4          // .step-item: grid-template-columns 28px → 间距 4px
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
