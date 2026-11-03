pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import SetupUi
import OrbbecShot 1.0

// QML 冒烟测试根对象：把每个组件与页面都实例化一遍，让绑定与 onCompleted 真正跑起来。
// 只由 `--selftest --qml-smoke [--view <视图>] [--option <键>]` 使用（截图版本里还会截图），
// 普通启动不会创建它。
// 一个组件由 App.qml 注入（appFrameComponent），这里只负责摆放：主窗口 Main 的控制器
// 摆到 --view 指定的那一屏；外壳 AppFrame 再单独实例化一遍全部页面（不可见），覆盖
// Main 不显示的那些页面。
// SetupController 依赖 Host / SetupEngine 两个上下文对象，冒烟只用它们读状态、不调用引擎。
ApplicationWindow {
    id: smoke
    // 冒烟根窗口本身就是窗口：它的子项直接排进 contentItem，和下面截图窗口的
    // ContentItem("QmlSmoke") 共用同一个 QQuickRootItem。两棵 940×650 的外壳实例因此
    // 会画在 RootItem 的同一块区域里，截图把下面那棵也算进去，文字叠成双影
    // （选项页、失败页都能看到）。截图模式（shotPath 非空）下整窗不显示，只留截图窗口在画；
    // 平时冒烟窗口要显示，内容才是活的。
    visible: smoke.shotPath.length === 0
    width: theme.windowW
    height: theme.windowH

    // 外壳注入（--qml-smoke --view <name> --option <key>），缺省就是首屏与第一个选项。
    // 注意：context property 是 QVariant；缺省时读到的可能是 undefined，直接读会抛
    // "Cannot read property of undefined"，所以要先量一下 typeof 再比较。
    property int optionIndex: (typeof smokeOption !== "undefined" && smokeOption !== null
                               && Number(smokeOption) > 0) ? Number(smokeOption) : 0
    // 截图模式下的输出文件；为空表示只是构造检查、不截图。
    property string shotPath: ""
    property Component appFrameComponent

    readonly property string currentView: (typeof smokeView !== "undefined" && smokeView !== null
                                          && smokeView.view !== undefined)
                                          ? smokeView.view : "options"
    readonly property bool currentUninstalling: (typeof smokeView !== "undefined" && smokeView !== null
                                                 && smokeView.uninstalling !== undefined)
                                                 ? smokeView.uninstalling : false
    // 4 个安装选项的键，与 main.cpp 的 --option 解析顺序一致。
    readonly property var optionKeys: ["shortcutDesktop", "assoc3mf", "assocStl", "launchAfterInstall"]
    // --dir <路径>：截图换成别的安装位置（如不可写 / 空间不足的位置），缺省是默认目录。
    readonly property string dirOverride: (typeof smokeDir !== "undefined" && smokeDir !== null
                                           && String(smokeDir).length > 0) ? String(smokeDir) : ""

    // 步骤表是 var 数组，逐项复制成普通 JS 对象再交给外壳组件：直接传 QML 对象时，
    // 跨组件赋值后 label 会变成 undefined（截图里步骤名空白）。
    function stepsOf(list) {
        const out = []
        for (let i = 0; i < list.length; ++i)
            out.push({ "label": String(list[i].label), "state": String(list[i].state) })
        return out
    }

    // 令牌表与基础部件
    UiTheme { id: theme }
    UiBtn { text: "确定"; primary: true }
    UiBtn { text: "删除"; danger: true }
    UiBtn { text: "禁用"; enabledState: false }
    BrandMark { base: theme.brand; accent: theme.brandSoft }
    StepList {
        steps: [{ "label": "一", "state": "done" }, { "label": "二", "state": "active" },
                { "label": "三", "state": "pending" }]
    }

    // 与 App.qml 同理：控制器用 property 而不是 id，Main 的 required property 要的是对象属性。
    property SetupController ctl: SetupController {
        uninstalling: smoke.currentUninstalling
        Component.onCompleted: {
            view = smoke.currentView
            if (smoke.dirOverride.length > 0)
                installOptions.installDir = smoke.dirOverride
            // 截图时取消一个选项：写的是控制器自己的 installOptions（页面绑定在它身上），
            // applyShotState 再从 ctl 读回来交给截图外壳。
            if (smoke.optionIndex > 0) {
                const k = smoke.optionKeys[smoke.optionIndex]
                installOptions[k] = !installOptions[k]
            }
        }
    }

    // 主窗口：由 QmlSmoke 负责可见性，冒烟里不显示（Main 自己的 visible: true 绑定会覆盖它）。
    Main {
        id: mainWin
        visible: false
        Component.onCompleted: bindController(smoke.ctl)
    }

    // 外壳与全部页面：独立于 Main 再构造一次，检查每页的绑定；不显示。
    // （只有截图窗口里那份会显示。）
    // 步骤表照抄一份（stepsOf），与截图那条路径一致：直接传 QML 对象时步骤名会变成空白。
    Loader {
        sourceComponent: smoke.appFrameComponent
        onLoaded: {
            item.visible = false
            item.installSteps = smoke.stepsOf(ctl.installSteps)
            item.uninstallSteps = smoke.stepsOf(ctl.uninstallSteps)
        }
        // 注意：本 Loader 与下面的截图 Loader 不是同一份对象（各自 onLoaded 一次），
        // 截图窗口里的步骤表由 App.qml 的 applyShotState 按 --view 摆。
    }

    // 截图：App.qml 把路径交给本对象后才走到这里。
    // 用 appFrameComponent 创建一次真实尺寸的外壳（940×650，与 Main 的窗口同尺寸），
    // 放进一个真正的 ApplicationWindow 里显示：抓屏只需要一个上屏窗口，入口那条
    // `--selftest --qml-smoke` 下 App.qml 的 Main 是隐藏的。
    ApplicationWindow {
        // 窗口按视觉尺寸给：系统缩放 125% 时窗口 940×650 在屏幕上就是 1175×813 物理像素；
        // 内容固定 940×650，正好铺满（没有多余底色边）。截图尺寸因此随系统缩放变化，
        // tools/capture-ui.ps1 用 QT_SCALE_FACTOR=1 固定成 940×650，与 Main 的窗口一致。
        id: shotWindow
        visible: smoke.shotPath.length > 0
        x: 0
        y: 0
        width: theme.windowW
        height: theme.windowH
        color: theme.page
        title: qsTr("OrbbecSlicer 安装向导")
        flags: Qt.Window | Qt.FramelessWindowHint

        Loader {
            id: shotLoader
            anchors.fill: parent
            sourceComponent: smoke.appFrameComponent
            onLoaded: {
                // 截图时只留 ctl.viewIndex（← --view）对应的那一页，见 App.qml 的 showOnly()。
                // 选项状态不在这里推：ctl 的 Component.onCompleted 可能比本 Loader 晚，
                // 那时读到的是默认值。页面直接绑定在 ctl.installOptions 上，无需复制；
                // 步骤表也由 applyShotState 绑到 ctl 上，跟着 --view 走。
                item.applyShotState({ "ctl": ctl })
                item.style = smoke.currentUninstalling ? "uninstall" : "install"
                item.showOnly(smoke.currentView)
                // 截图要看的是"940×650 窗口"在屏幕上的实际像素：窗口按物理像素放大 dpr 倍，
                // 内容保持 940×650 视觉尺寸，放大后再按设备像素栅格化，和真实缩放下一致。
                item.visible = true
            }
        }
        // 抓屏：main.cpp 在截图构建里注册了单例 QmlShot（OrbbecShot 模块），给它写
        // capture 键就会在窗口显示后抓一张并退出。普通构建不 import 这个模块。
        Timer {
            running: smoke.shotPath.length > 0
            interval: 1200
            repeat: false
            onTriggered: {
                shotWindow.show()
                shotWindow.raise()
                shotWindow.requestActivate()
                QmlShot.capture = smoke.shotPath
            }
        }
    }
}
