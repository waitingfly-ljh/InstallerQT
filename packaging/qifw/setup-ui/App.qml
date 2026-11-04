pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// 引擎入口：main.cpp 通过 qrc:/SetupUi/App.qml 加载本文件，Main 负责创建并显示窗口。
// 根类型是 Item（而不是 ApplicationWindow）：窗口由 Main 自己创建并显示，
// 本文件只持有唯一的控制器实例并连接引擎信号。
Item {
    id: app

    // 截图构建注入（--view <视图> / --shot-dir <目录>）；普通启动里两者都是空串。
    // main.cpp 总会注入 viewName / shotDir / smokeView / smokeOption；它们都是 QVariant，
    // 读不存在的名字会得到 undefined，字符串化后为空，所以普通构建里也可放心读。
    // 必须在文件靠前的位置声明：QML 里"读当前作用域里声明在后面的属性"不可靠
    // （onCompleted 里读到过空串）。所以这里显式绑定宿主注入的全局 viewName / shotDir。
    property string viewName: typeof viewNameGlobal !== "undefined" ? viewNameGlobal : ""
    property string shotDir: typeof shotDirGlobal !== "undefined" ? shotDirGlobal : ""
    // --selftest --qml-smoke：把 QmlSmoke（全部页面）挂到下面的 Loader 上。
    readonly property bool smoke: Qt.application.arguments.indexOf("--qml-smoke") >= 0
    function shotPathFor(v, d) {
        return v.length > 0 ? (d.length > 0 ? d + "/" + v + ".png" : v + ".png") : ""
    }
    readonly property string shotPath: shotPathFor(app.viewName, app.shotDir)
    // 截图模式（-DORBBEC_SETUP_SHOT 构建）：main.cpp 注入 shotModel 并注册
    // OrbbecShot.QmlShot 单例。QmlSmoke 每次都往另一份 App 占位模型里加载本文件，
    // 那份模型是空对象，本文件的控制器按普通启动走（且它所在的窗口始终不可见）。
    readonly property bool shotMode: typeof shotModel !== "undefined" && shotModel !== null
                                              && Object.keys(shotModel).length > 0

    // 先于第 0 帧创建控制器：截图/冒烟模式下按模型摆位，普通启动走 start()
    // （按"已安装/未安装"选首屏）。冒烟根对象 QmlSmoke 有自己的控制器。
    //
    // 控制器刻意声明成 property 而不是 id：id 绑不到 Main 的 required property 上
    // （把 id 写进属性值会绑定该 id 的"对象指针属性"，普通对象没有这个属性，于是整个
    // Main 拿到 null）。库里新建的 SetupController 会自动挂到本对象的子级，生命周期不变；
    // 外部仍然可以读写 app.ctl.view。
    property SetupController ctl: SetupController {
        uninstalling: app.shotMode && shotModel.uninstalling !== undefined ? shotModel.uninstalling : false
        Component.onCompleted: {
            if (!app.shotMode) {
                start()
                return
            }
            if (shotModel.failure !== undefined) {
                failureCode = shotModel.failure
                failureCodeText = String(shotModel.failure)
                failureMessage = shotModel.message || ""
            }
            if (shotModel.view !== undefined)
                view = shotModel.view
        }
    }

    // 冒烟根对象（--selftest --qml-smoke）：在主窗口之后声明，保持它最后创建。
    Loader { id: smokeLoader }


    Connections {
        target: Host.engine
        function onFinished(code, summary) { ctl.onEngineFinished(code, summary) }
        function onCancelled() { ctl.onEngineCancelled() }
    }

    Main {
        id: main
        // 只给对象值：不要用 ctl（App 里同名的 id 赋给 required 属性会变成指针，Main 读到 null）。
        Component.onCompleted: bindController(app.ctl)
        // 冒烟模式下会再挂一个 QmlSmoke（它自己有一份可见的主窗口），这一个只留作参照。
        visible: !app.smoke
    }

    // 截图：QmlSmoke 在自己的窗口里截（抓屏在 main.cpp 的 QmlShot 单例里做）。
    //   --selftest --qml-smoke → QmlSmoke（实例化全部页面，控制器按 --view 摆位）
    //   其他 → 本文件直接启动（按 shotModel 摆位），截图由 QmlSmoke 之外的路径完成。
    // 文件名 = <--shot-dir>/<--view>.png。
    Component.onCompleted: {
        const png = shotPathFor(app.viewName, app.shotDir)
        // 根对象是 Item，Main 作为嵌套 Window 不会自动显示；普通启动显式 show。
        if (!app.smoke)
            main.show()
        if (app.smoke) {
            smokeLoader.setSource("qrc:/SetupUi/QmlSmoke.qml", {
                "shotPath": png,
                // 组件只声明、不实例化：交给 QmlSmoke 自己 Loader 创建。
                "appFrameComponent": smokeFrameComponent
            })
        }
    }

    Component {
        id: smokeFrameComponent
        AppFrame {
            // 冒烟组件是独立的实例，不再自行推状态：把截图用的控制器接受进来。
            // 选项页直接绑定到控制器（与 Main.qml 一致）：--option 改的就是这份状态，
            // 复制一份快照反而会因为 ctl 的 onCompleted 时序而拿到默认值。
            property var shotCtl
            StackLayout {
                anchors.fill: parent
                // 内容区与 Main.qml 一致：只显示 controller 的 currentIndex 那一页。
                // StackLayout 会忽略页面自身的 visible，所以 showOnly() 改的是 ctl.flowView。
                currentIndex: shotCtl !== undefined ? shotCtl.viewIndex : 0

                OptionsPage {
                    id: optionsPage
                    installParentDir: "C:\\Program Files"
                    shortcutDesktop: true
                    assoc3mf: true
                    assocStl: false
                    launchAfterInstall: true
                    notice: ""
                    onDirChanged: (d) => {}
                    onOptionChanged: (k, v) => {}
                }
                MaintenancePage {
                    id: maintenancePage
                    mode: "upgrade"
                    currentVersion: "1.0.0"
                    targetVersion: "1.1.0"
                    riskAcknowledged: false
                    onRiskToggled: (c) => {}
                }
                // 进度档位在截图组件里写死：截图模式下 Host.engine 没有在跑，读它有值也是 0%。
                ProgressPage { id: progressPage; heading: "正在安装 OrbbecSlicer"; lead: "请保持窗口开启。安装过程不会上传本机项目或用户预设。"; phase: "正在准备组件"; progress: 62; detail: "正在验证安装包完整性..." }
                CompletePage { id: completePage; title: "完成"; description: "就绪"; primaryText: "立即启动"; secondaryText: "查看文件"; showSecondary: true }
                FailurePage { id: failurePage; errorCode: "1205"; errorText: "写入文件时权限不足" }
                DataScopePage { id: dataScopePage; removeAllData: false }
                UninstallConfirmPage { id: confirmPage; removeAllData: false; keepDataDir: true; installDir: "C:\\OrbbecSlicer" }
                CompletePage {
                    id: uninstalledPage
                    title: "卸载完成"
                    description: "程序文件已移除，个人预设和偏好已保留。"
                    primaryText: "结束"
                    secondaryText: "查看文件"
                    showSecondary: true
                }
            }
            // 冒烟组件是独立的实例，不再自行推状态：controller 与步骤表都来自调用方。
            function showOnly(view) {
                if (shotCtl !== undefined)
                    shotCtl.setView(view)
            }
            function applyShotState(state) {
                if (state.ctl === undefined)
                    return
                shotCtl = state.ctl
                // 截图时 --option 改的是 ctl.installOptions，页面绑在它身上。页面自身的
                // dirChanged / optionChanged 只在用户操作时发，截图时不会触发，所以不接回控制器。
                // 步骤表同样绑到 ctl 上（而不是抄一份快照）：setView() 切到进度/完成页时，
                // 侧栏要跟着变成 done/active/pending。
                installSteps = Qt.binding(() => shotCtl.installSteps)
                uninstallSteps = Qt.binding(() => shotCtl.uninstallSteps)
                optionsPage.installParentDir = Qt.binding(() => shotCtl.installOptions.installParentDir)
                optionsPage.shortcutDesktop = Qt.binding(() => shotCtl.installOptions.shortcutDesktop)
                optionsPage.assoc3mf = Qt.binding(() => shotCtl.installOptions.assoc3mf)
                optionsPage.assocStl = Qt.binding(() => shotCtl.installOptions.assocStl)
                optionsPage.launchAfterInstall = Qt.binding(() => shotCtl.installOptions.launchAfterInstall)
                // 截图外壳上 applyShotState 之后，optionsPage.installParentDir 是绑到 ctl 上的；
                // 拖后腿的只有"ctl 还没给默认值"：ctl 的 Component.onCompleted 比截图外壳晚跑。
                // 那时仍是空串，就用与 SetupController.resetOptions 相同的默认值兜底。
                if (shotCtl.installOptions.installParentDir.length === 0) {
                    shotCtl.installOptions.installParentDir = Host.normalizeDirPath(Host.defaultInstallParent())
                    shotCtl.installOptions.installDir = Host.installDirForParent(shotCtl.installOptions.installParentDir)
                }
            }
        }
    }
}
