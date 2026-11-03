// Main.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import SetupUi

// 外壳主窗口：无边框 940×650，按控制器状态切换页面。
// 控制器由 App.qml / QmlSmoke 创建并把对象赋给本窗口的 ctl（只赋值、不需要在本文件声明 required），本文件只负责窗口外壳与页面装配。
ApplicationWindow {
    id: window
    objectName: "mainWindow"
    // 控制器由外层（App.qml / QmlSmoke）的 required 属性创建并注入：外层先给的是占位对象，
    // 构造完成后再换成真正的控制器；页面绑定在拿到真控制器之前读到的是占位值，不会是 null。
    //
    // 声明位置：QML 绑定是按名解析、与声明位置无关；这里放在引用点之前只是为了便于阅读。
    readonly property SetupController ctl: rootCtl.obj

    // 占位 → 真控制器的开关：外层在构造结束后调用 bindController() 切换。
    QtObject {
        id: rootCtl
        property QtObject obj: placeholderCtl
    }

    function bindController(controller) { rootCtl.obj = controller }

    // 占位控制器：与真控制器同类型、默认值，页面在真控制器注入前读它不会报错。
    readonly property SetupController placeholderCtl: SetupController { }
    UiTheme { id: theme }
    visible: true
    width: theme.windowW
    height: theme.windowH
    minimumWidth: theme.windowMinW
    minimumHeight: theme.windowMinH
    title: qsTr("OrbbecSlicer 安装向导")
    flags: Qt.Window | Qt.FramelessWindowHint
    color: theme.page

    onClosing: (close) => {
        // 安装/卸载进行中不允许关闭：交给引擎完成或被取消。
        if (Host.engine.busy)
            close.accepted = false
    }

    // 关闭确认：安装进行中不允许直接退出。
    function requestClose() {
        if (Host.engine.busy)
            return
        Qt.quit()
    }

    // 截图模式的触发在 App.qml（窗口显示、页面摆好之后）；本文件不需要知道截图的事。

    // 无边框窗口没有系统标题栏：整块内容由 AppFrame 绘制（标题栏可拖动）。
    // 直接声明在这里、不再包一层 Loader：ApplicationWindow 只把直接子节点放进 contentItem，
    // Loader 装出来的外壳虽然建好了却不进场景，页面也就从不实例化。
    // 必须锚满整窗：ApplicationWindow 只给直接子项落默认位置（0,0），不会设尺寸，
    // 外壳不锚满就是 0×0，里面的布局排不到内容区，页面永远不建。
    AppFrame {
        anchors.fill: parent
        windowTitle: ctl.view === "dataScope" || ctl.view === "confirm" || ctl.view === "uninstalled"
                     ? qsTr("卸载 OrbbecSlicer")
                     : qsTr("OrbbecSlicer 安装向导")
        sideHeadline: ctl.view === "dataScope" || ctl.view === "confirm"
                      ? qsTr("卸载\nOrbbecSlicer")
                      : qsTr("让创意\n开始成形")
        sideFoot: {
            if (ctl.view === "dataScope" || ctl.view === "confirm")
                return qsTr("卸载过程无需登录\n无需互联网连接")
            return qsTr("OrbbecSlicer %1").arg(ctl.targetVersion)
        }
        installSteps: ctl.installSteps
        uninstallSteps: ctl.uninstallSteps
        onMinimizeRequested: window.showMinimized()
        onCloseRequested: window.close()
        style: ctl.uninstalling ? "uninstall" : "install"

        StackLayout {
            id: pageStack
            currentIndex: {
                const v = ctl.view
                if (v === "options") return 0
                if (v === "maintenance") return 1
                if (v === "progress") return 2
                if (v === "complete") return 3
                if (v === "failure") return 4
                if (v === "dataScope") return 5
                if (v === "confirm") return 6
                if (v === "uninstalled") return 7
                return 0
            }

            // 页面自己按窗口尺寸算出内容区大小（见各页顶部的 contentW/contentH 说明），
            // 这里只把它们横向钉在内容区里，不再 anchors.fill。
            // 切换页面用 StackLayout：隐藏的页不参与排版，只显示 ctl.view 那一页。

            // ---- 安装设置 ----
            OptionsPage {
                id: optionsPage
                objectName: "optionsPage"
                visible: ctl.view === "options"
                installDir: ctl.installOptions.installDir
                shortcutDesktop: ctl.installOptions.shortcutDesktop
                assoc3mf: ctl.installOptions.assoc3mf
                assocStl: ctl.installOptions.assocStl
                launchAfterInstall: ctl.installOptions.launchAfterInstall
                notice: ctl.cancelled ? qsTr("安装已取消，已写入的文件已清除。") : ""
                onDirChanged: (d) => ctl.installOptions.installDir = d
                onOptionChanged: (key, value) => ctl.installOptions[key] = value
                onInstallRequested: {
                    // 只输入、没按回车就点安装时，输入框文字已经通过 onDirChanged 同步；
                    // 这里再补一次，保证控制器拿到的是要安装的目录。
                    ctl.installOptions.installDir = optionsPage.installDir
                    ctl.beginInstall()
                }
            }

            // ---- 维护：修复 / 升级 / 降级 ----
            MaintenancePage {
                visible: ctl.view === "maintenance"
                mode: ctl.mode === "fresh" ? "repair" : ctl.mode
                currentVersion: ctl.installed.version
                targetVersion: ctl.targetVersion
                riskAcknowledged: ctl.riskAcknowledged
                onRiskToggled: (c) => ctl.riskAcknowledged = c
                onCancelRequested: Qt.quit()
                onProceedRequested: {
                    ctl.installOptions.installDir = Host.normalizeDirPath(ctl.installed.installDir)
                    ctl.beginInstall()
                }
            }

            // ---- 安装过程 ----
            ProgressPage {
                visible: ctl.view === "progress"
                heading: ctl.uninstalling ? qsTr("正在卸载 OrbbecSlicer")
                           : ctl.mode === "repair" ? qsTr("正在修复 OrbbecSlicer")
                           : ctl.mode === "upgrade" ? qsTr("正在升级 OrbbecSlicer")
                           : ctl.mode === "downgrade" ? qsTr("正在降级 OrbbecSlicer")
                           : qsTr("正在安装 OrbbecSlicer")
                lead: ctl.uninstalling ? qsTr("正在移除程序文件，请保持窗口开启。")
                                     : qsTr("请保持窗口开启。安装过程不会上传本机项目或用户预设。")
                onCancelRequested: Host.engine.cancel()
            }

            // ---- 安装/维护完成 ----
            CompletePage {
                visible: ctl.view === "complete"
                title: ctl.mode === "repair" ? qsTr("修复完成")
                         : ctl.mode === "upgrade" ? qsTr("升级完成")
                         : ctl.mode === "downgrade" ? qsTr("降级完成")
                         : qsTr("安装完成")
                description: ctl.mode === "repair" ? qsTr("修复完成，原有配置可继续使用。")
                               : ctl.mode === "upgrade" ? qsTr("升级完成，兼容配置已迁移。")
                               : ctl.mode === "downgrade" ? qsTr("降级完成，配置快照已保留。")
                               : qsTr("OrbbecSlicer 已准备就绪。")
                primaryText: qsTr("立即启动")
                onPrimaryAction: {
                    if (!Host.launchApp(ctl.installOptions.installDir.length
                                        ? ctl.installOptions.installDir : ctl.installed.installDir)) {
                        Qt.quit()
                    }
                }
            }

            // ---- 安装未完成 ----
            FailurePage {
                visible: ctl.view === "failure"
                errorCode: ctl.failureCodeText
                errorText: ctl.failureMessage
                onOpenLogsRequested: Host.revealLogs()
                onRetryRequested: ctl.retry()
            }

            // ---- 卸载：数据范围 ----
            DataScopePage {
                visible: ctl.view === "dataScope"
                removeAllData: ctl.removeAllData
                onModeSelected: (removeAll) => ctl.removeAllData = removeAll
                onNextRequested: ctl.view = "confirm"
                onCancelRequested: Qt.quit()
            }

            // ---- 卸载：确认 ----
            UninstallConfirmPage {
                visible: ctl.view === "confirm"
                removeAllData: ctl.removeAllData
                keepDataDir: ctl.keepDataDir
                installDir: ctl.installed.installDir
                onKeepDataDirToggled: (c) => ctl.keepDataDir = c
                onBackRequested: ctl.view = "dataScope"
                onConfirmRequested: ctl.beginUninstall()
            }

            // ---- 卸载完成 ----
            CompletePage {
                visible: ctl.view === "uninstalled"
                title: qsTr("卸载完成")
                description: ctl.removeAllData
                           ? qsTr("程序文件已移除，本机应用数据已清除。")
                           : qsTr("程序文件已移除，个人预设和偏好已保留。")
                primaryText: qsTr("结束")
                secondaryText: qsTr("查看文件")
                showSecondary: ctl.keepDataDir
                onPrimaryAction: Qt.quit()
                onSecondaryAction: Host.revealLogs()
            }
        }
    }
}
