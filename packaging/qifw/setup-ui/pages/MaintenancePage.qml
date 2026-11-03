// MaintenancePage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// 维护确认页：修复 / 升级 / 降级。降级需勾选风险确认才能继续。
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
    property string mode: "repair"           // repair | upgrade | downgrade
    property string currentVersion: ""
    property string targetVersion: ""
    property bool riskAcknowledged: false
    signal proceedRequested(mode: string)
    signal cancelRequested()
    signal riskToggled(bool checked)

    readonly property string title: mode === "repair" ? qsTr("修复 OrbbecSlicer")
                                  : mode === "upgrade" ? qsTr("升级 OrbbecSlicer")
                                  : qsTr("降级 OrbbecSlicer")
    readonly property string lead: mode === "repair"
        ? qsTr("检测到相同版本。修复会重新写入程序文件，并保留全部用户数据。")
        : mode === "upgrade"
        ? qsTr("新版本将覆盖现有程序，并迁移兼容的本地配置。")
        : qsTr("安装包版本低于现有版本。确认风险后才可继续。")
    readonly property string primaryText: mode === "repair" ? qsTr("开始修复")
                                        : mode === "upgrade" ? qsTr("开始升级")
                                        : qsTr("确认并降级")
    readonly property var retained: [
        qsTr("自定义预设"), qsTr("校准结果"), qsTr("软件偏好"),
        qsTr("打印机信息"), qsTr("账号会话"), qsTr("LAN 访问码")
    ]

    ColumnLayout {
        width: page.contentW
        height: page.contentH
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: page.title
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
            text: page.lead
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            lineHeight: 1.7
            font.pixelSize: theme.fontLead
            color: theme.muted
        }
        Item { Layout.preferredHeight: 24 }

        // 评审稿 .version-grid { grid-template-columns: 1fr 54px 1fr; gap: 10px; margin: 18px 0 }。
        // 固定宽度（内容区宽度随窗口变化，Row 里的 width: parent.width 量不出内容区宽度）。
        Row {
            Layout.topMargin: 18
            spacing: 10
            readonly property real boxW: 260
            width: 260 * 2 + 54 + 20
            Rectangle {
                width: parent.boxW
                implicitHeight: boxA.implicitHeight + 30
                radius: 6
                clip: true
                color: theme.panelSoft
                border.width: 1
                border.color: theme.line
                Column {
                    id: boxA
                    anchors.left: parent.left
                    width: parent.width - 30
                    anchors.leftMargin: 15
                    anchors.verticalCenter: parent.verticalCenter
                    Text { text: qsTr("当前版本"); font.family: theme.fontFamily; font.pixelSize: theme.fontFoot; color: theme.muted }
                    Item { width: 1; height: 5 }
                    Text { text: page.currentVersion; font.family: theme.fontFamily; font.pixelSize: 18; font.bold: true; color: theme.text }
                }
            }
            Text {
                width: 54
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
                text: "→"
                font.family: theme.fontFamily
                font.pixelSize: 22
                color: theme.brand
            }
            Rectangle {
                width: parent.boxW
                implicitHeight: boxB.implicitHeight + 30
                radius: 6
                clip: true
                color: theme.panelSoft
                border.width: 1
                border.color: theme.line
                Column {
                    id: boxB
                    anchors.left: parent.left
                    width: parent.width - 30
                    anchors.leftMargin: 15
                    anchors.verticalCenter: parent.verticalCenter
                    Text { text: qsTr("安装包版本"); font.family: theme.fontFamily; font.pixelSize: theme.fontFoot; color: theme.muted }
                    Item { width: 1; height: 5 }
                    Text { text: page.targetVersion; font.family: theme.fontFamily; font.pixelSize: 18; font.bold: true; color: theme.text }
                }
            }
        }

        // 保留清单（.info-card + .retain-list 两列，✓ 前缀为成功色）
        Rectangle {
            Layout.topMargin: 18
            Layout.fillWidth: true
            implicitHeight: retain.implicitHeight + 28
            radius: theme.radius
            color: theme.infoSoft
            border.width: 1
            border.color: theme.infoLine
            Column {
                id: retain
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14
                spacing: 2
                Text {
                    text: qsTr("以下数据将继续保留")
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    font.bold: true
                    color: theme.textStrong
                }
                // 两列（.retain-list { margin: 12px 0 0; grid-template-columns: 1fr 1fr; gap: 7px 14px }）
                Grid {
                    width: parent.width
                    topPadding: 12
                    columns: 2
                    columnSpacing: 14
                    rowSpacing: 7
                    Repeater {
                        model: page.retained
                        delegate: Row {
                            required property string modelData
                            spacing: 7
                            height: 21
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "✓"
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                font.bold: true
                                color: theme.success
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                color: theme.textBody
                            }
                        }
                    }
                }
            }
        }

        Item {
            visible: page.mode === "downgrade"
            Layout.preferredHeight: 12
        }
        Rectangle {
            visible: page.mode === "downgrade"
            Layout.fillWidth: true
            implicitHeight: warnCol.implicitHeight + 24
            radius: theme.radius
            color: theme.warningSoft
            border.width: 1
            border.color: theme.warningLine
            Column {
                id: warnCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                spacing: 8
                Text { text: qsTr("降级可能导致配置不兼容"); font.family: theme.fontFamily; font.pixelSize: theme.fontBody; font.bold: true; color: theme.warningInk }
                Text {
                    wrapMode: Text.WordWrap
                    width: parent.width
                    text: qsTr("安装前会创建可恢复快照。旧版本无法识别的配置将被隔离，不会直接覆盖。")
                    font.family: theme.fontFamily; font.pixelSize: theme.fontBody; color: theme.warningInk
                }
                Rectangle {
                    implicitHeight: 30
                    implicitWidth: riskAcknowledgedText.implicitWidth + 26
                    function toggle() {
                        const v = !page.riskAcknowledged
                        page.riskToggled(v)
                    }
                    Rectangle {
                        width: 16; height: 16; radius: 3
                        anchors.verticalCenter: parent.verticalCenter
                        border.width: 1
                        border.color: page.riskAcknowledged ? theme.brand : theme.line
                        color: page.riskAcknowledged ? theme.brand : theme.panel
                        Text {
                            anchors.centerIn: parent
                            visible: page.riskAcknowledged
                            text: "✓"
                            color: theme.white
                            font.pixelSize: 11
                            font.bold: true
                        }
                    }
                    Text {
                        id: riskAcknowledgedText
                        anchors.left: parent.left
                        anchors.leftMargin: 24
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("我已了解风险，继续安装旧版本")
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

        // 操作行贴底（评审稿 .setup-actions { margin-top:auto; padding-top:22px }）
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            Item { Layout.fillWidth: true }
            UiBtn { text: qsTr("取消"); onClicked: page.cancelRequested() }
            UiBtn {
                text: page.primaryText
                primary: true
                enabledState: page.mode !== "downgrade" || page.riskAcknowledged
                onClicked: page.proceedRequested(page.mode)
            }
        }
    }
}
