// AppFrame.qml
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import SetupUi

// 外壳框架：42px 自定义标题栏 + 228px 深色侧栏 + 内容区。
// 页面通过 default property content 挂到内容区。
Item {
    id: frame
    UiTheme { id: theme }

    signal minimizeRequested()
    signal closeRequested()
    signal stepClicked(int index)

    property string windowTitle: qsTr("OrbbecSlicer 安装向导")
    property string sideHeadline: qsTr("让创意\n开始成形")
    property string sideFoot: qsTr("OrbbecSlicer %1").arg(Host.version)
    // install | uninstall：卸载使用独立的三步列表（数据范围 → 确认 → 完成）
    property string style: "install"
    property var installSteps: []
    property var uninstallSteps: []
    property int currentStep: 0
    property bool showMinimize: true
    readonly property var steps: style === "uninstall" ? uninstallSteps : installSteps
    default property alias content: contentHost.data

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // --- 标题栏 ---
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: theme.titleBarH
            color: theme.topbar
            // 评审稿 .setup-titlebar 的下边线（1px，在 42px 之内）
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                        height: 1; color: theme.titleLine }
            // 标题栏拖动区盖住整条标题栏；页面上的输入框滚到这里时，滚轮事件会沿着
            // 父链冒泡到拖动区——不拦下就会被当成"拖动窗口"，拖动中收不到位置变化，
            // 松手后窗口才突然跳走。这里直接忽略滚轮。
            WheelHandler { onWheel: (e) => { e.accepted = true } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 0
                spacing: 9

                BrandMark { Layout.alignment: Qt.AlignVCenter; base: theme.brand; accent: theme.brandSoft }

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: frame.windowTitle
                    color: theme.titleText
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                }
                Item { Layout.fillWidth: true }

                // 最小化
                Item {
                    Layout.preferredWidth: 46
                    Layout.fillHeight: true
                    visible: frame.showMinimize
                    Rectangle {
                        anchors.fill: parent
                        color: minMa.containsMouse ? theme.titleHover : "transparent"
                        Behavior on color { ColorAnimation { duration: theme.animFast } }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "−"
                        color: theme.titleMuted
                        font.pixelSize: 16
                    }
                    MouseArea {
                        id: minMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: frame.minimizeRequested()
                    }
                }

                // 关闭
                Item {
                    Layout.preferredWidth: 46
                    Layout.fillHeight: true
                    Rectangle {
                        anchors.fill: parent
                        color: closeMa.containsMouse ? theme.danger : "transparent"
                        Behavior on color { ColorAnimation { duration: theme.animFast } }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: closeMa.containsMouse ? theme.white : theme.titleMuted
                        font.pixelSize: 16
                    }
                    MouseArea {
                        id: closeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: frame.closeRequested()
                    }
                }
            }

            // 标题栏拖动
            MouseArea {
                anchors.fill: parent
                anchors.rightMargin: 92
                property point pressPos
                onPressed: (m) => pressPos = Qt.point(m.x, m.y)
                onPositionChanged: (m) => {
                    if (!pressed)
                        return
                    // 从 MouseArea 向上找所属的 Window；不依赖某个具体的 id。
                    const w = frame.Window.window
                    if (w) {
                        w.x += m.x - pressPos.x
                        w.y += m.y - pressPos.y
                    }
                }
            }
        }

        // --- 主体 --- 侧栏 | 内容区
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // 侧栏
            Rectangle {
                id: sideArea
                Layout.preferredWidth: theme.sideW
                Layout.fillHeight: true
                clip: true
                // 布局会把子项 reprant 到它自己身上；侧栏里的光斑与文字列因此显式钉在 sideArea 上，
                // 否则 anchors.fill: parent 挂的是布局，尺寸与内边距都会落空。
                // 评审稿 .setup-side 的底色：linear-gradient(175deg, sideTop 0%, sideMid 58%, sideBottom 100%)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: theme.sideTop }
                    GradientStop { position: 0.58; color: theme.sideMid }
                    GradientStop { position: 1.0; color: theme.sideBottom }
                }
                // 左上光斑：radial-gradient(circle at 10% 18%, rgba(55,192,184,.35), transparent 35%)。
                // Qt 只有线性渐变，径向用 Image 画：resources/glow.png 是 228×300 的预生成图
                // （公式见 SideGlow.qml），按侧栏实际尺寸拉伸。
                Image {
                    parent: sideArea
                    anchors.fill: parent
                    source: "qrc:/glow.png"
                    fillMode: Image.Stretch
                    smooth: true
                    opacity: 0.5
                }

                ColumnLayout {
                    // 评审稿 .setup-side { padding: 34px 24px }；底部版本号单独贴底 24px。
                    parent: sideArea
                    anchors.fill: parent
                    anchors.leftMargin: 24
                    anchors.rightMargin: 24
                    anchors.topMargin: 34
                    anchors.bottomMargin: 24
                    spacing: 0

                    Text {
                        text: frame.sideHeadline
                        color: theme.white
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSideTitle
                        font.bold: true
                        lineHeight: 1.4
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    Item { Layout.preferredHeight: 30 }

                    StepList {
                        Layout.fillWidth: true
                        steps: frame.steps
                        Component.onCompleted: stepClicked.connect((i) => frame.stepClicked(i))
                    }

                    Item { Layout.fillHeight: true }

                    Text {
                        text: frame.sideFoot
                        color: theme.sideMuted
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontFoot
                        lineHeight: 1.6
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }
                }
            }

            // 内容区（评审稿 .setup-main background: 白色）
            Rectangle {
                id: contentArea
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: theme.surface

                Item {
                    id: contentHost
                    // 同上：统一钉在内容区矩形上，而不是布局。
                    parent: contentArea
                    anchors.fill: parent
                    anchors.leftMargin: theme.contentPaddingH
                    anchors.rightMargin: theme.contentPaddingH
                    anchors.topMargin: theme.contentPaddingV
                    anchors.bottomMargin: 24
                }
            }
        }
    }
}
