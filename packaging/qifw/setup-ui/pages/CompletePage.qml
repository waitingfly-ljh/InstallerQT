// CompletePage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// 完成页：完成图标 + 结果说明 + 立即启动。
// 同时用于安装、修复/升级/降级、卸载三种完成态（标题与按钮文案由外部给出）。
Item {
    id: page

    // 页面绘制在 AppFrame 的内容区里（尺寸 = 窗口 − 标题栏/侧栏/内边距）。但页面拿到的
    // parent 尺寸在这个构造顺序下是 0（AppFrame 布局晚一步才定下来，页面的 anchors.fill
    // 不会跟着重算），内容区的 ColumnLayout 于是按最窄一行（97px）排版，自动换行的地方
    // 一律提前折行。所以布局不跟 parent 走，直接按窗口尺寸算内容区。窗口尺寸未知时
    // （隐身的冒烟副本）退回默认 940×650。
    readonly property real contentW: (page.Window.width > 0 ? page.Window.width : theme.windowW)
                                     - theme.sideW - theme.contentPaddingH * 2
    readonly property real contentH: (page.Window.height > 0 ? page.Window.height : theme.windowH)
                                     - theme.titleBarH - theme.contentPaddingV - 24
    UiTheme { id: theme }
    property string title: qsTr("安装完成")
    property string description: qsTr("OrbbecSlicer 已准备就绪。")
    property string primaryText: qsTr("立即启动")
    property bool showSecondary: false
    property string secondaryText: ""
    property bool launchEnabled: true
    signal primaryAction()
    signal secondaryAction()

    ColumnLayout {
        width: page.contentW
        height: page.contentH
        spacing: 0

        // 评审稿 .complete-icon { margin: 34px auto 14px }——"34px" 是图标上方留白；整块随
        // .complete-copy 在内容区里居中（上下两块 flex 留白相等），图标并不贴着页面顶部。
        Item { Layout.fillHeight: true }
        Item {
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: 70; implicitHeight: 70 + 14          // 14 = 投影向下溢出的高度

            // box-shadow: 0 10px 24px rgba(15,143,136,.22)：矩形 + 高斯模糊，底下叠两层近似
            // （模糊层再淡一点，边缘就不会是硬轮廓）。
            // 阴影：越往外越淡的同心圆，圆心比图标低 10px（box-shadow 的 y 偏移）。
            Repeater {
                model: [
                    { "pad": 22, "dy": 12, "a": 0.04 },
                    { "pad": 16, "dy": 12, "a": 0.05 },
                    { "pad": 10, "dy": 11, "a": 0.06 },
                    { "pad": 5,  "dy": 10, "a": 0.06 }
                ]
                delegate: Rectangle {
                    required property var modelData
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: modelData.dy
                    width: 70 + modelData.pad * 2
                    height: width
                    radius: width / 2
                    color: theme.alpha(theme.brand, modelData.a)
                }
            }
            Rectangle {
                width: 70; height: 70; radius: 35
                color: theme.brand
                Text {
                    anchors.centerIn: parent
                    text: "✓"
                    color: theme.white
                    font.family: theme.fontFamily
                    font.pixelSize: 34
                }
            }
        }
        Item { Layout.preferredHeight: 14 }
        Text {
            Layout.alignment: Qt.AlignHCenter
            horizontalAlignment: Text.AlignHCenter
            text: page.title
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle + 1           // .complete-copy h2: 24px
            font.weight: Font.DemiBold
            color: theme.text
        }
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.alignment: Qt.AlignHCenter
            horizontalAlignment: Text.AlignHCenter
            text: page.description
            wrapMode: Text.WordWrap
            lineHeight: 1.7
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.muted
        }

        Item { Layout.fillHeight: true }

        // 操作行贴底（评审稿 .setup-actions { margin-top:auto; padding-top:22px }）
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            Item { Layout.fillWidth: true }
            UiBtn {
                visible: page.showSecondary
                text: page.secondaryText
                onClicked: page.secondaryAction()
            }
            UiBtn {
                text: page.primaryText
                primary: true
                enabledState: page.launchEnabled
                onClicked: page.primaryAction()
            }
        }
    }
}
