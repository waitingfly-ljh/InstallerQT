// ProgressPage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// 安装过程页：任务名、百分比、进度条、细节行、取消。
// 进度来自 Host.engine 的真实输出（阶段 + 事件），不播放固定动画。
Item {
    id: page
    UiTheme { id: theme }
    // 页面绘制在 AppFrame 的内容区里（尺寸 = 窗口 − 标题栏/侧栏/内边距）。但页面拿到的
    // parent 尺寸在这个构造顺序下是 0（AppFrame 布局晚一步才定下来，页面的 anchors.fill
    // 不会跟着重算），内容区的 ColumnLayout 于是按最窄一行（97px）排版，自动换行的地方
    // 一律提前折行。所以布局不跟 parent 走，直接按窗口尺寸算内容区。窗口尺寸未知时
    // （隐身的冒烟副本）退回默认 940×650。
    readonly property real contentW: (page.Window.width > 0 ? page.Window.width : theme.windowW)
                                     - theme.sideW - theme.contentPaddingH * 2
    readonly property real contentH: (page.Window.height > 0 ? page.Window.height : theme.windowH)
                                     - theme.titleBarH - theme.contentPaddingV - 24

    property string heading: qsTr("正在安装 OrbbecSlicer")
    property string lead: qsTr("请保持窗口开启。安装过程不会上传本机项目或用户预设。")
    property string phase: Host.engine.phase
    property int progress: Host.engine.progress
    property string detail: Host.engine.detail
    property bool canCancel: true
    // 收尾阶段：引擎已结束，进度固定显示 100%，取消按钮禁用。
    property bool complete: false
    signal cancelRequested()

    ColumnLayout {
        id: col
        x: 0
        y: 0
        width: page.contentW
        height: page.contentH
        spacing: 0

        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: page.heading
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.DemiBold
            color: theme.text
        }
        // 导语（.setup-view .lead { margin: 9px 0 24px }：上 9、下 24）
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.fillWidth: true
            text: page.lead
            wrapMode: Text.WordWrap
            lineHeight: 1.7
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.muted
        }
        Item { Layout.preferredHeight: 24 }

        // 评审稿 .progress-visual { width: min(500px, 100%); margin: 58px auto 20px }。
        // 横向居中、纵向排在导语下方；取消行由下面的 fillHeight 间隔顶到底。
        // 宽度直接取页面实际宽度的 50%（940−228−92 = 620 → 500），不受布局改写 width 的影响。
        Item {
            id: visual
            Layout.fillWidth: true
            Layout.topMargin: 58 + 20              // margin: 58px ... 20px → 上 58 = 导语后 24 + 34；下 20 由 fillHeight 间隔给
            Layout.preferredHeight: visualCol.implicitHeight
            Layout.alignment: Qt.AlignHCenter

            Column {
                id: visualCol
                width: Math.min(500, page.contentW)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 9

                // 标题行（.progress-title { display:flex; justify-content:space-between; margin-bottom:9px }）：
                // 任务名左、百分比右。用锚定而不是 Row：Row 不会给绝对定位的百分比让位。
                Item {
                    width: parent.width
                    height: percentText.height > phaseText.height ? percentText.height : phaseText.height

                    Text {
                        id: percentText
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: (page.complete ? 100 : page.progress) + "%"
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.muted
                    }
                    Text {
                        id: phaseText
                        anchors.left: parent.left
                        anchors.right: percentText.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: page.phase
                        elide: Text.ElideRight
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        font.bold: true
                        color: theme.text
                    }
                }

                // .progress-track { height: 9px; border-radius: 20px; background: 浅灰 }
                Rectangle {
                    id: track
                    width: parent.width
                    height: 9
                    radius: 20
                    clip: true
                    color: theme.track

                    Rectangle {
                        height: parent.height
                        radius: 20
                        width: parent.width * Math.max(0, Math.min(1, (page.complete ? 100 : page.progress) / 100))
                        // .progress-fill: linear-gradient(90deg, 品牌色, 品牌浅色)
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: theme.brand }
                            GradientStop { position: 1.0; color: theme.trackFillEnd }
                        }
                        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    }
                }

                // .progress-detail { margin-top: 11px; text-align: center }
                Text {
                    width: parent.width
                    topPadding: 2                     // 列距 9 + 2 = 11
                    horizontalAlignment: Text.AlignHCenter
                    text: page.detail
                    wrapMode: Text.WordWrap
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontLead
                    color: theme.muted
                }
            }
        }

        Item { Layout.fillHeight: true }
        // 操作行贴底（评审稿 .setup-actions { margin-top:auto; padding-top:22px }）
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            Item { Layout.fillWidth: true }
            UiBtn {
                text: qsTr("取消")
                enabledState: page.canCancel && !page.complete
                onClicked: page.cancelRequested()
            }
        }
    }
}
