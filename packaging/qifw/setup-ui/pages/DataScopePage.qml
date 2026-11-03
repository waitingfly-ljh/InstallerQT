// DataScopePage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// 卸载 1/3：选择数据范围。默认"保留个人数据"，分类表随选择变化。
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
    signal modeSelected(bool removeAll)
    signal nextRequested()
    signal cancelRequested()

    readonly property var dataRows: removeAllData
        ? [
            { "name": qsTr("自定义预设、校准结果"), "action": qsTr("删除") },
            { "name": qsTr("软件偏好、地区设置"), "action": qsTr("删除") },
            { "name": qsTr("缓存与日志"), "action": qsTr("删除") },
            { "name": qsTr("登录令牌、云服务凭据"), "action": qsTr("删除") },
            { "name": qsTr("安装目录之外的项目文件"), "action": qsTr("保留") }
        ]
        : [
            { "name": qsTr("自定义预设、校准结果"), "action": qsTr("保留") },
            { "name": qsTr("软件偏好、地区设置"), "action": qsTr("保留") },
            { "name": qsTr("缓存与日志"), "action": qsTr("删除") },
            { "name": qsTr("登录令牌、云服务凭据"), "action": qsTr("删除") },
            { "name": qsTr("安装目录之外的项目文件"), "action": qsTr("保留") }
        ]

    ColumnLayout {
        width: page.contentW
        height: page.contentH
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("如何处理个人数据？")
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
            text: qsTr("选择本机数据处理范围。")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            lineHeight: 1.7
            font.pixelSize: theme.fontLead
            color: theme.muted
        }
        Item { Layout.preferredHeight: 24 }

        // 两个数据范围选项：默认"保留个人数据"（removeAllData=false）。
        Column {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: [
                    { "removeAll": false,
                      "title": qsTr("保留个人数据"),
                      "detail": qsTr("预设、校准结果、偏好与设备信息保留；缓存与登录凭据清除。") },
                    { "removeAll": true,
                      "title": qsTr("删除本机全部应用数据"),
                      "detail": qsTr("预设、校准结果、偏好与设备信息一并删除。") }
                ]
                delegate: Rectangle {
                    id: optionCard
                    required property var modelData
                    readonly property bool selected: page.removeAllData === modelData.removeAll
                    width: tableColumn ? tableColumn.width : 0
                    implicitHeight: optionRow.implicitHeight + 20
                    radius: theme.radius
                    color: selected ? theme.brandSoft : theme.panel
                    border.width: 1
                    border.color: selected ? theme.brand : theme.line

                    Row {
                        id: optionRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10

                        Rectangle {
                            width: 16
                            height: 16
                            radius: 8
                            anchors.verticalCenter: parent.verticalCenter
                            border.width: 1
                            border.color: optionCard.selected ? theme.brand : theme.line
                            color: theme.panel
                            Rectangle {
                                anchors.centerIn: parent
                                width: 8
                                height: 8
                                radius: 4
                                visible: optionCard.selected
                                color: theme.brand
                            }
                        }
                        Column {
                            width: optionRow.width - 26
                            spacing: 2
                            Text {
                                text: optionCard.modelData.title
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                font.bold: true
                                color: theme.text
                            }
                            Text {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: optionCard.modelData.detail
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontSmall
                                color: theme.muted
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            page.removeAllData = optionCard.modelData.removeAll
                            page.modeSelected(optionCard.modelData.removeAll)
                        }
                    }
                }
            }
        }
        Item { Layout.preferredHeight: 14 }

        // 数据分类表：普通 Column + Repeater，避免带 Row 属性的自定义组件。
        Rectangle {
            id: tableColumn
            Layout.fillWidth: true
            implicitHeight: tableCol.implicitHeight + 20
            Layout.preferredHeight: implicitHeight
            radius: theme.radius
            color: theme.panel
            border.width: 1
            border.color: theme.line

            Column {
                id: tableCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 10
                spacing: 0

                Item {
                    width: parent.width
                    height: 26
                    Text {
                        width: parent.width * 0.68
                        text: qsTr("数据")
                        font.family: theme.fontFamily; font.pixelSize: theme.fontSmall
                        font.bold: true; color: theme.muted
                    }
                    Text {
                        x: parent.width * 0.68
                        width: parent.width * 0.32
                        text: page.removeAllData ? qsTr("删除全部") : qsTr("默认卸载")
                        font.family: theme.fontFamily; font.pixelSize: theme.fontSmall
                        font.bold: true; color: theme.muted
                    }
                }

                Repeater {
                    model: page.dataRows
                    delegate: Item {
                        id: rowItem
                        required property var modelData
                        width: tableCol.width
                        height: 26
                        Rectangle {
                            width: parent.width; height: 1
                            anchors.bottom: parent.bottom
                            color: theme.lineSoft
                        }
                        Text {
                            width: parent.width * 0.68
                            anchors.verticalCenter: parent.verticalCenter
                            text: rowItem.modelData.name
                            font.family: theme.fontFamily; font.pixelSize: theme.fontSmall
                            color: theme.text
                        }
                        Text {
                            x: parent.width * 0.68
                            width: parent.width * 0.32
                            anchors.verticalCenter: parent.verticalCenter
                            text: rowItem.modelData.action
                            font.family: theme.fontFamily; font.pixelSize: theme.fontSmall
                            color: rowItem.modelData.action === qsTr("删除") ? theme.danger : theme.muted
                        }
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
            UiBtn { text: qsTr("下一步"); primary: true; onClicked: page.nextRequested() }
        }
    }
}
