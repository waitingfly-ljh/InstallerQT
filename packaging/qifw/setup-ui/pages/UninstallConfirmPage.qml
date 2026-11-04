// UninstallConfirmPage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// 卸载 2/3：确认 + 保留用户数据文件夹勾选。
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
    property bool removeAllData: false
    property bool keepDataDir: false
    property string installDir: ""
    signal keepDataDirToggled(bool checked)
    signal backRequested()
    signal confirmRequested()

    readonly property string summary: (removeAllData
        ? qsTr("将移除程序文件，并删除本机的全部 OrbbecSlicer 应用数据：预设、校准结果、偏好、缓存与凭据。")
        : qsTr("将移除程序文件，保留自定义预设、校准结果、偏好与非敏感设备信息；缓存和登录凭据会被清除。"))
        + qsTr(" 安装目录内的文件会被一并删除，个人项目请放在安装目录之外。")
        + (keepDataDir ? qsTr(" 同时保留安装时创建的用户数据文件夹。") : "")

    ColumnLayout {
        width: page.contentW
        height: page.contentH
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("确认卸载")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.DemiBold
            color: theme.text
        }
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.fillWidth: true
            text: qsTr("确认数据处理范围。")
            wrapMode: Text.WordWrap
            lineHeight: 1.7
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.muted
        }

        Item { Layout.preferredHeight: 24 }

        // 所选范围摘要：随数据范围与"保留用户数据文件夹"勾选同步更新。
        Text {
            Layout.fillWidth: true
            text: page.summary
            wrapMode: Text.WordWrap
            lineHeight: 1.65
            font.family: theme.fontFamily
            font.pixelSize: theme.fontBody
            color: theme.textBody
        }
        Item { Layout.preferredHeight: 14 }

        Rectangle {
            Layout.fillWidth: true
            Layout.maximumWidth: 560
            implicitHeight: safeCol.implicitHeight + 28
            radius: theme.radius
            color: theme.infoSoft
            border.width: 1
            border.color: theme.infoLine
            Column {
                id: safeCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14                       // .info-card padding: 14px 16px
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 4
                Item { width: 1; height: 2 }
                Text { text: qsTr("不会受影响"); font.family: theme.fontFamily; font.pixelSize: theme.fontBody; font.bold: true; color: theme.infoInk }
                Text {
                    // Column 不把宽度传下去：Text 默认取 implicitWidth（最长一行），
                    // 不封口时卡片会被撑到最大宽度。
                    width: safeCol.width
                    wrapMode: Text.WordWrap
                    lineHeight: 1.65
                    text: qsTr("程序目录之外的项目与导出文件，以及当前账号的云端数据。")
                    font.family: theme.fontFamily; font.pixelSize: theme.fontBody; color: theme.infoInk
                }
                Item {
                    implicitHeight: 30 + 4
                    implicitWidth: keepDataDirText.implicitWidth + 26
                    // 勾选项行（与安装设置页的 check-row 同一套排版：16px 勾选框 + 24px 文案起点），
                    // 上方多留 4px 与说明文字分开。
                    function toggle() {
                        const v = !page.keepDataDir
                        page.keepDataDirToggled(v)
                    }
                    Rectangle {
                        width: 16; height: 16; radius: 3
                        anchors.verticalCenter: parent.verticalCenter
                        border.width: 1
                        border.color: page.keepDataDir ? theme.brand : theme.line
                        color: page.keepDataDir ? theme.brand : theme.panel
                        Text {
                            anchors.centerIn: parent
                            visible: page.keepDataDir
                            text: "✓"
                            color: theme.white
                            font.pixelSize: 11
                            font.bold: true
                        }
                    }
                    Text {
                        id: keepDataDirText
                        anchors.left: parent.left
                        anchors.leftMargin: 24
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("保留用户数据文件夹")
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.text
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: parent.toggle()
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }

        // 操作行贴底（评审稿 .setup-actions { margin-top:auto; padding-top:22px }）；
        // .left-action 靠左，其余按钮靠右。
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            UiBtn { text: qsTr("上一步"); onClicked: page.backRequested() }
            Item { Layout.fillWidth: true }
            UiBtn {
                text: qsTr("确认卸载")
                danger: true
                onClicked: page.confirmRequested()
            }
        }
    }
}
