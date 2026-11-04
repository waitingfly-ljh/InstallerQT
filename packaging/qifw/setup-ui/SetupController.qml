pragma ComponentBehavior: Bound
import QtQuick

// 安装器界面状态：页面流、安装选项、已安装版本判定。
// 界面只在这里决定"显示哪一屏"，实际安装/卸载由 Host.engine 执行。
QtObject {
    id: ctl

    // --- 页面流 ---
    // options | maintenance | progress | complete | failure | dataScope | confirm | uninstalled
    property string view: "options"
    property bool uninstalling: false
    readonly property var installSteps: [
        { "label": qsTr("安装设置"), "state": installStepState(0) },
        { "label": qsTr("安装过程"), "state": installStepState(1) },
        { "label": qsTr("安装完成"), "state": installStepState(2) }
    ]
    function installStepState(i) {
        if (flowView === "options") return i === 0 ? "active" : "pending"
        if (flowView === "progress") return i === 0 ? "done" : i === 1 ? "active" : "pending"
        if (flowView === "failure") return i === 0 ? "done" : i === 1 ? "active" : "pending"
        // complete（含维护完成）都在最后一屏
        return i < 2 ? "done" : "active"
    }
    readonly property var uninstallSteps: [
        { "label": qsTr("数据范围"), "state": uninstallStepState(0) },
        { "label": qsTr("确认卸载"), "state": uninstallStepState(1) },
        { "label": qsTr("卸载完成"), "state": uninstallStepState(2) }
    ]
    function uninstallStepState(i) {
        if (flowView === "dataScope") return i === 0 ? "active" : "pending"
        if (flowView === "confirm") return i === 0 ? "done" : i === 1 ? "active" : "pending"
        if (flowView === "progress") return i < 2 ? "done" : "active"
        if (flowView === "uninstalled") return i < 2 ? "done" : "active"
        // 卸载过程中失败：停在第二步
        return i < 2 ? "done" : "pending"
    }
    readonly property var steps: uninstalling ? uninstallSteps : installSteps

    // 截图（--view）专用的流程视图：截图模式下引擎没在跑，ctl.view 由 App.qml 按 --view 摆位。
    // 侧栏步骤表以它为准，而不是直接看 ctl.view：截图外壳的页面靠 StackLayout 的 currentIndex
    // 显示，页面自身的 visible 被设成 false 不生效（见 App.qml applyShotState）。
    // 普通启动里 setView() 从不被调用，它恒等于 view。
    property string flowView: view

    // 内容区 StackLayout 的 currentIndex（Main.qml 与截图外壳共用这一个映射）。
    // 截图时 App.qml 调 setView() 摆位，侧栏步骤表也按 flowView 算。
    function setView(v) {
        view = v
        flowView = v
    }
    readonly property int viewIndex: {
        const v = flowView
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

    // --- 安装选项 ---
    property QtObject installOptions: QtObject {
        // 界面收集/显示的是父文件夹；installDir 是由它拼出的最终安装目录（引擎入参）。
        property string installParentDir: ""
        property string installDir: ""
        property bool shortcutDesktop: true
        property bool assoc3mf: true
        property bool assocStl: false
        property bool launchAfterInstall: true
    }
    function resetOptions() {
        installOptions.installParentDir = Host.normalizeDirPath(Host.defaultInstallParent())
        installOptions.installDir = Host.installDirForParent(installOptions.installParentDir)
        installOptions.shortcutDesktop = true
        installOptions.assoc3mf = true
        installOptions.assocStl = false
        installOptions.launchAfterInstall = true
    }

    // --- 已安装版本 ---
    property var installed: ({ "installed": false, "version": "", "installDir": "" })
    property string targetVersion: Host.payloadVersion
    property bool riskAcknowledged: false
    // 本次安装流程的意图：在点击"安装"时从 mode 固化下来。
    // 安装成功后 installed 会变成"已安装且版本相同"，mode 会变成 repair；
    // 完成页不能再用重算后的 mode，否则全新安装会显示"修复完成"。
    property string runMode: "fresh"
    readonly property string mode: {
        if (!installed.installed) return "fresh"
        const a = compareVersions(targetVersion, installed.version)
        return a === 0 ? "repair" : a > 0 ? "upgrade" : "downgrade"
    }
    function compareVersions(a, b) {
        const pa = String(a || "").split(/[.-]/).map(x => parseInt(x, 10) || 0)
        const pb = String(b || "").split(/[.-]/).map(x => parseInt(x, 10) || 0)
        for (let i = 0; i < Math.max(pa.length, pb.length); ++i) {
            const x = pa[i] || 0, y = pb[i] || 0
            if (x !== y) return x > y ? 1 : -1
        }
        return 0
    }

    // --- 失败与卸载 ---
    property int failureCode: -1
    property string failureCodeText: ""
    property string failureMessage: ""
    property bool removeAllData: false
    property bool keepDataDir: false
    property bool cancelled: false
    // 进度收尾：成功时显示 100% 并停留，失败/取消也短暂停留后再切页。
    property bool finishing: false
    property int pendingCode: -1
    property string pendingSummary: ""
    readonly property int displayProgress: finishing ? 100 : Host.engine.progress

    // QtObject 没有默认属性，子对象必须挂到具体属性上。
    property Timer finishTimer: Timer {
        interval: 600
        repeat: false
        onTriggered: ctl.applyFinish()
    }

    // 从系统卸载入口启动（--uninstall）：跳过维护判断，直接进入卸载流程。
    readonly property bool uninstallOnly: typeof uninstallMode !== "undefined" && uninstallMode === true
    readonly property string installDirOverride: (typeof installDirPath !== "undefined"
                                                  && installDirPath !== null) ? String(installDirPath) : ""

    function start() {
        refreshInstalled()
        if (uninstallOnly) {
            const dir = installDirOverride.length > 0 ? installDirOverride : installed.installDir
            installed = { "installed": true, "version": installed.version, "installDir": dir }
            uninstalling = true
            view = "dataScope"
            return
        }
        resetOptions()
        view = installed.installed ? "maintenance" : "options"
    }

    function refreshInstalled() {
        Host.refreshInstalled()
        installed = Host.installed
    }

    function beginInstall() {
        runMode = mode
        cancelled = false
        if (installed.installed) {
            // 维护（修复/升级/降级）必须落回原来的安装目录：即使历史上装成过自定义目录名，
            // 也不能因为父文件夹语义被改到 <parent>\OrbbecSlicer。
            installOptions.installDir = Host.normalizeDirPath(installOptions.installDir)
        } else {
            // 全新安装：由父文件夹算出最终目录（"D:"、尾部斜杠等写法在这里统一）。
            const parent = installOptions.installParentDir.length > 0
                         ? installOptions.installParentDir
                         : Host.defaultInstallParent()
            installOptions.installParentDir = Host.normalizeDirPath(parent)
            installOptions.installDir = Host.installDirForParent(installOptions.installParentDir)
        }
        if (installOptions.installDir.length === 0) {
            failureCode = 2
            failureCodeText = "2"
            failureMessage = qsTr("安装位置为空，请重新填写。")
            view = "failure"
            return
        }
        view = "progress"
        Host.engine.startInstall(installOptions.installDir, {
            "shortcutDesktop": installOptions.shortcutDesktop,
            "assoc3mf": installOptions.assoc3mf,
            "assocStl": installOptions.assocStl,
            "launchAfterInstall": installOptions.launchAfterInstall
        })
    }

    function onEngineFinished(code, summary) {
        pendingCode = code
        pendingSummary = summary
        finishing = code === 0
        finishTimer.interval = code === 0 ? 600 : 300
        finishTimer.restart()
    }

    function applyFinish() {
        finishing = false
        const code = pendingCode
        if (code === 0) {
            if (uninstalling) {
                uninstalling = false
                view = "uninstalled"
            } else {
                refreshInstalled()
                view = "complete"
            }
            return
        }
        uninstalling = false
        failureCode = code
        failureCodeText = code > 0 ? String(code) : ""
        failureMessage = pendingSummary
        view = "failure"
    }

    function onEngineCancelled() {
        // 取消也短暂停留，避免进度条瞬间消失。
        pendingCode = -1
        finishing = false
        finishTimer.stop()
        cancelTimer.start()
    }

    property Timer cancelTimer: Timer {
        interval: 300
        repeat: false
        onTriggered: {
            ctl.uninstalling = false
            ctl.cancelled = true
            ctl.view = ctl.installed.installed ? "maintenance" : "options"
        }
    }

    function retry() {
        view = installed.installed ? "maintenance" : "options"
    }

    function beginUninstall() {
        uninstalling = true
        view = "progress"
        Host.engine.startUninstall(installed.installDir, removeAllData, keepDataDir)
    }
}
