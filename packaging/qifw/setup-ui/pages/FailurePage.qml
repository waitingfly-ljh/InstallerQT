// FailurePage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// 安装未完成页：回滚说明 + 诊断信息 + 查看日志 / 重新尝试。
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
    property string rollbackTitle: qsTr("原版本和原配置已恢复")
    property string rollbackText: qsTr("程序文件已回滚到原版本，配置快照校验通过。你可以继续使用原版本，或重新尝试安装。")
    property string errorCode: ""
    property string errorText: ""
    property string logPath: Host.logPath
    signal openLogsRequested()
    signal retryRequested()

    ColumnLayout {
        width: page.contentW
        height: page.contentH
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("安装未完成")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.DemiBold
            color: theme.text
        }
        // 导语（.setup-view .lead { margin: 9px 0 24px }）
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.fillWidth: true
            text: qsTr("写入新版本时发生异常，系统已停止后续操作。")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            lineHeight: 1.7
            font.pixelSize: theme.fontLead
            color: theme.muted
        }
        Item { Layout.preferredHeight: 24 }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: okCol.implicitHeight + 28
            radius: theme.radius
            color: theme.successSoft
            border.width: 1
            border.color: theme.successLine
            Column {
                id: okCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14                       // .info-card / .success-card padding: 14px 16px
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 4
                Text { text: page.rollbackTitle; font.family: theme.fontFamily; font.pixelSize: theme.fontBody; font.bold: true; color: theme.successInk }
                Text {
                    wrapMode: Text.WordWrap
                    width: parent.width
                    text: page.rollbackText
                    lineHeight: 1.65                     // 卡片统一 line-height: 1.65
                    font.family: theme.fontFamily; font.pixelSize: theme.fontBody; color: theme.successInk
                }
            }
        }

        Item { Layout.preferredHeight: 12 }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: diagCol.implicitHeight + 28
            radius: theme.radius
            color: theme.infoSoft
            border.width: 1
            border.color: theme.infoLine
            Column {
                id: diagCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14                       // .info-card / .success-card padding: 14px 16px
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 4
                Text { text: qsTr("诊断信息"); font.family: theme.fontFamily; font.pixelSize: theme.fontBody; font.bold: true; color: theme.infoInk }
                Text {
                    wrapMode: Text.WordWrap
                    width: parent.width
                    text: {
                        const code = page.errorCode.length ? qsTr("错误代码 INS-%1").arg(page.errorCode) : qsTr("错误代码未知")
                        return page.errorText.length ? code + "，" + page.errorText : code
                    }
                    lineHeight: 1.65
                    font.family: theme.fontFamily; font.pixelSize: theme.fontBody; color: theme.infoInk
                }
                Text {
                    width: parent.width
                    elide: Text.ElideMiddle
                    text: qsTr("日志：%1").arg(page.logPath)
                    font.family: theme.fontFamily; font.pixelSize: theme.fontSmall; color: theme.infoInk
                }
            }
        }

        Item { Layout.fillHeight: true }

        // 操作行贴底（评审稿 .setup-actions { margin-top:auto; padding-top:22px }）
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            UiBtn {
                text: qsTr("打开日志")
                onClicked: page.openLogsRequested()
            }
            Item { Layout.fillWidth: true }
            UiBtn {
                text: qsTr("重新尝试")
                primary: true
                onClicked: page.retryRequested()
            }
        }
    }
}
