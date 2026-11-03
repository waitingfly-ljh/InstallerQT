// OptionsPage.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import SetupUi

// 安装设置页：目录、空间提示、四项选项、安装按钮。
// 布局与其它页面一致：一整列 ColumnLayout 铺满内容区，按钮行跟在内容后面靠右
// （评审稿 .setup-actions：justify-content: flex-end）。
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
    width: page.contentW
    height: page.contentH

    property real requiredBytes: 1.8 * 1024 * 1024 * 1024   // 与评审稿"预计需要 1.8 GB"一致
    property string installDir: ""
    // 安装目录的规范化形式（C:/x/ → C:\x）。安装按钮只看它。
    readonly property string effectiveInstallDir: Host.normalizeDirPath(page.installDir)
    // 输入框显示的文字。不用 TextInput.text 绑定 installDir：那样每次 textEdited 都会
    // 触发"是否形成绑定循环"的检查，日志里的 "Binding loop detected" 会让 capture-ui 判失败；
    // 这里让文字只由下列事件推动：初次构造、installDir 在编辑之外被改（控制器给默认目录）、
    // 编辑结束、浏览对话框选完。
    property string dirText: ""
    // 用户正在输入框里编辑（textEdited 之后、编辑结束或失去焦点之前）。为 true 时不从
    // installDir 回填输入框：控制器回显的规范化路径会把中间态（末尾的斜杠、小写盘符）
    // 改掉，输入时光标会跳。
    property bool dirEditing: false
    // installDir 在编辑之外变化（启动时控制器给默认目录、--option 截图等）时回填输入框。
    // 不能写成 onInstallDirChanged {...}：同一个属性上还有一条更新 installDir 的绑定
    // （installDir: ctl.installOptions.installDir），两者并存会被 QML 编译器判成
    // "Property value set multiple times" 并丢掉绑定，所以用 Connections。
    // installDir 在构造时就可能有值（onChanged 不触发），Component.onCompleted 再补一次。
    Connections {
        target: page
        function onInstallDirChanged() { if (!page.dirEditing) page.dirText = page.installDir }
    }
    property bool shortcutDesktop: true
    property bool assoc3mf: true
    property bool assocStl: false
    property bool launchAfterInstall: true
    property string notice: ""                               // 取消安装后的提示
    signal installRequested()
    signal dirChanged(string dir)
    signal optionChanged(string key, bool value)

    // 目录校验：目录可写 + 空间足够，任一失败禁用安装按钮。
    readonly property string dirProblem: page.effectiveInstallDir.length === 0
                                             ? qsTr("请填写安装位置")
                                             : Host.probeDirectory(page.effectiveInstallDir)
    readonly property real free: Host.freeBytes(page.effectiveInstallDir)
    readonly property bool spaceShort: free >= 0 && free < requiredBytes
    readonly property bool canInstall: dirProblem.length === 0 && !spaceShort && Host.payloadReady
    // 冒烟断言用：每个勾选项的键 + 当前是否选中（顺序与界面上两列的排列一致）。
    readonly property var optionDiagnostics: [
        { "key": "shortcutDesktop", "checked": page.shortcutDesktop },
        { "key": "assoc3mf", "checked": page.assoc3mf },
        { "key": "assocStl", "checked": page.assocStl },
        { "key": "launchAfterInstall", "checked": page.launchAfterInstall }
    ]

    function fmtBytes(n) {
        if (n < 0) return qsTr("未知")
        const gb = n / (1024 * 1024 * 1024)
        return gb >= 1 ? gb.toFixed(1) + " GB" : Math.max(1, Math.round(n / (1024 * 1024))) + " MB"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("安装设置")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.DemiBold                  // .setup-view h2 { font-weight: 650 }
            color: theme.text
        }
        // 导语（.setup-view .lead { margin: 9px 0 24px }：上 9、下 24）
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.fillWidth: true
            text: qsTr("确认安装位置和常用选项。")
            wrapMode: Text.WordWrap
            lineHeight: 1.7
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.muted
        }
        Item { Layout.preferredHeight: 24 }
        // 取消安装后的提示（评审稿只有一个导语，页面额外状态用一行文字叠在导语下方；
        // 不再用 34px 提示条，免得把整页一推 48px，截图的纵向节奏和评审稿对不上）。
        Text {
            visible: page.notice.length > 0
            Layout.fillWidth: true
            Layout.topMargin: 4
            text: page.notice
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontBody
            color: theme.warningInk
        }

        Text {
            text: qsTr("安装位置")
            font.family: theme.fontFamily
            font.pixelSize: theme.fontBody
            font.weight: Font.DemiBold                  // .form-label { font-weight: 600 }
            color: theme.text
        }
        Item { Layout.preferredHeight: 7 }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            // 目录输入框内联：UiField 是"输入框 + 别名"的薄封装，页面只需一个实例。
            Rectangle {
                id: dirField
                Layout.fillWidth: true
                implicitHeight: 38
                radius: theme.radius
                color: theme.panel
                border.width: 1
                border.color: dirInput.activeFocus ? theme.brand : theme.line
                TextInput {
                    id: dirInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    selectByMouse: true
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    color: theme.text
                    selectionColor: theme.brandSoft
                    selectedTextColor: theme.text
                    // 平时跟随 dirText；用户编辑期间不回填（见 dirEditing）。
                    // 回填写的是文字，不是绑定：绑定在 dirEditing 变 true 时断开，之后由
                    // OptionsPage 的 onInstallDirChanged 与 EditingFinished / 浏览对话框回填。
                    text: page.dirEditing ? text : page.dirText
                    onTextEdited: {
                        page.dirEditing = true
                        page.dirChanged(text)
                    }
                    onEditingFinished: {
                        page.dirEditing = false
                        // 编辑结束时把规范化后的路径回填到输入框。
                        page.dirText = page.installDir
                    }
                }
            }
            UiBtn {
                text: qsTr("浏览")
                implicitHeight: 38               // 与目录框同高（评审稿 .path-row 两格等高；按钮默认 36）
                onClicked: folderPicker.open()
            }
        }
        Item { Layout.preferredHeight: 7 }

        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSmall
            color: (page.dirProblem.length > 0 && page.installDir.length > 0) ? theme.danger
                 : page.spaceShort ? theme.warning
                 : !Host.payloadReady ? theme.warning : theme.muted
            text: {
                // 目录问题优先于开发模式的负载提示：用户要看到的是"这个位置不能用"。
                if (page.installDir.length > 0 && page.dirProblem.length > 0)
                    return page.dirProblem
                if (page.spaceShort)
                    return qsTr("该磁盘仅剩 %1，需要 %2。").arg(page.fmtBytes(page.free)).arg(page.fmtBytes(page.requiredBytes))
                if (!Host.payloadReady && Host.mode === "development")
                    return qsTr("开发模式：未指定安装包，请用 --payload <路径> 启动")
                return qsTr("预计需要 %1 可用空间，当前可用 %2。").arg(page.fmtBytes(page.requiredBytes)).arg(page.fmtBytes(page.free))
            }
        }

        // 四个安装选项，两列（评审稿 .check-grid { gap: 10px 16px; margin-top: 18px }）。
        // 每项 = 16px 勾选框 + 文案，点击整行切换。
        Grid {
            Layout.topMargin: 18
            columns: 2
            columnSpacing: 56
            rowSpacing: 0
            Repeater {
                // 只在模型变化时重建：model 若写成内联数组字面量，QML 每次触发绑定重算
                // （比如 diagnostics 的属性变了）都会重建勾选框、清掉悬停状态。
                model: [
                    { "key": "shortcutDesktop", "label": qsTr("创建桌面快捷方式") },
                    { "key": "assoc3mf", "label": qsTr("关联 .3mf 文件") },
                    { "key": "assocStl", "label": qsTr("关联 .stl 文件") },
                    { "key": "launchAfterInstall", "label": qsTr("安装完成后启动软件") }
                ]
                delegate: Item {
                    id: optionRow
                    required property var modelData
                    readonly property bool checked: page[modelData.key] === true
                    // .check-row 行高 1.45 × 13px ≈ 19px，再让出 .check-grid 的行距 10px。
                    implicitHeight: 29
                    implicitWidth: optionLabel.implicitWidth + 26
                    function toggle() {
                        const v = !checked
                        page.optionChanged(modelData.key, v)
                        page[modelData.key] = v
                    }
                    Rectangle {
                        width: 16; height: 16; radius: 3
                        anchors.verticalCenter: parent.verticalCenter
                        border.width: 1
                        border.color: optionRow.checked ? theme.brand : theme.line
                        color: optionRow.checked ? theme.brand : theme.panel
                        Text {
                            anchors.centerIn: parent
                            visible: optionRow.checked
                            text: "✓"
                            color: theme.white
                            font.pixelSize: 11
                            font.bold: true
                        }
                    }
                    Text {
                        id: optionLabel
                        anchors.left: parent.left
                        anchors.leftMargin: 24
                        anchors.verticalCenter: parent.verticalCenter
                        text: optionRow.modelData.label
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.text
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: optionRow.toggle()
                    }
                }
            }
            // 冒烟检查用的只读标记（--selftest --qml-smoke 时由 main.cpp 读取）：
            // 每个勾选行都有一个铺满整行的 MouseArea，鼠标移上去显示手形。
            QtObject {
                objectName: "optionDiagnostics"
                readonly property var rows: page.optionDiagnostics
            }
        }

        // 操作行贴底（评审稿 .setup-actions { margin-top:auto; padding-top:22px }）
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            Item { Layout.fillWidth: true }
            UiBtn {
                text: qsTr("安装")
                primary: true
                enabledState: page.canInstall
                onClicked: {
                    // 先结束编辑：失焦回填规范化路径可能晚于点击，这里让发出去的目录就是
                    // 输入框里看到的内容（dirChanged 已在 textEdited 里发过）。
                    page.dirEditing = false
                    page.installRequested()
                }
            }
        }
    }

    FolderDialog {
        id: folderPicker
        title: qsTr("选择安装文件夹")
        onAccepted: {
            const p = Host.toNativePath(selectedFolder)
            if (p.length > 0) {
                page.dirEditing = false
                page.dirChanged(p)
                page.dirText = p
            }
        }
    }
}
