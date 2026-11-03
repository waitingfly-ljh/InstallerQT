// UiTheme.qml
// 视觉令牌的唯一来源：取值来自评审稿 OrbbecSlicer_安装与首次设置_交互原型.html 的 :root 变量。
// 任何页面都从这里取颜色与尺寸，不在各页硬编码色值（派生色、状态墨色也集中在这里）。
//
// 为什么是普通（非单例）QtObject：本工程通过绝对 qrc 路径加载模块（Qt 6.8.3），
// 单例要先读 qmldir 才知道自己是单例；模块根对象加载时 qmldir 还没读入，会被当成
// 普通组件创建，所有 Theme.xxx 都是 undefined 且不报错。改为普通组件后，各文件写
// `UiTheme { id: theme }` 靠属性绑定取值，不依赖模块解析顺序。
//
// 为什么不以 Theme 命名：qt_add_qml_module 的类型注册会跳过以 "Theme" 结尾的类型名，
// 而组件文件（UiBtn 等）要靠根目录 qmldir 送来的类型名才能解析令牌表。加上 Ui 前缀
// 后，令牌表与控件组件都在模块根，页面统一 import SetupUi。
//
// 注意：每个令牌只在这里写一次字面值，派生色直接引用同表内的字面量；
// 不要让令牌引用自己（如 `white: theme.white`），否则 Qt 报 Binding loop 且取到 undefined。
import QtQuick

QtObject {
    // 品牌与中性色
    readonly property color brand: "#0f8f88"
    readonly property color brandDark: "#0d6f6a"
    readonly property color brandSoft: "#e8f7f5"
    // 评审稿 .button:hover 的边框色（比 brandLine 更饱和，按钮悬停时用）
    readonly property color brandHoverLine: "#8acbc6"
    readonly property color brandLine: "#c3e6e2"
    readonly property color topbar: "#273438"
    readonly property color page: "#f3f5f6"                    // 页面外的底色（--page）
    readonly property color surface: "#ffffff"                 // 内容区（评审稿 .setup-main background: #fff）
    readonly property color panel: "#ffffff"
    readonly property color line: "#dfe4e7"
    readonly property color lineSoft: "#edf0f2"
    readonly property color text: "#263238"
    readonly property color textStrong: "#26383a"              // 卡片标题（.status-card strong 等）
    readonly property color textBody: "#47585b"                // .retain-item
    readonly property color panelSoft: "#fafbfb"               // .version-box 底色
    readonly property color track: "#e9eeef"                   // .progress-track
    readonly property color trackFillEnd: "#49c4bb"            // .progress-fill 渐变末端
    readonly property color muted: "#7a878d"
    readonly property color white: "#ffffff"

    // 状态色
    readonly property color danger: "#e5484d"
    readonly property color dangerSoft: "#fff1f1"
    readonly property color dangerLine: "#f6c9ca"
    readonly property color dangerInk: "#a32a2e"
    readonly property color warning: "#e79216"
    readonly property color warningSoft: "#fff7e9"
    readonly property color warningLine: "#f3dcae"
    readonly property color warningInk: "#8a5a06"
    readonly property color success: "#5aa900"
    readonly property color successSoft: "#eff9e8"
    readonly property color successInk: "#3d7a00"
    readonly property color successLine: "#d3ecc0"
    readonly property color info: "#2488e5"
    readonly property color infoSoft: "#edf6ff"
    readonly property color infoInk: "#155a9e"
    readonly property color infoLine: "#cfe4f9"

    // 交互派生色
    readonly property color brandHover: "#0e8079"
    // 深色侧栏上的品牌高亮（深色背景上 brandDark 几乎看不出，用更亮的青绿）
    readonly property color brandAccent: "#3fd0c4"
    readonly property color sideGlow: Qt.rgba(55 / 255, 192 / 255, 184 / 255, 0.35)  // 侧栏左上光斑
    readonly property color titleText: "#e9eef0"
    readonly property color titleMuted: "#d5dde0"
    readonly property color titleLine: "#151d1f"              // 标题栏下边线
    readonly property color titleHover: Qt.rgba(1, 1, 1, 0.10) // .window-btn:hover

    // 给某个令牌套上透明度（投影等需要"同色不同浓"的地方）。
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    // 侧栏深色渐变（评审稿 .setup-side）
    // 175deg：左上 #184c4b → 58% 处 #143c3e → 右下 #172d32；上面再叠一层左上径向光斑（见 AppFrame）。
    readonly property color sideTop: "#184c4b"
    readonly property color sideMid: "#143c3e"
    readonly property color sideBottom: "#172d32"
    readonly property color sideActiveDot: "#0f8f88"           // .step-item.active .step-dot 底
    readonly property color sideActiveRing: "#63d7d0"
    readonly property color sideDoneDot: Qt.rgba(15 / 255, 143 / 255, 136 / 255, 0.38)
    readonly property color sideDoneRing: "#79bcb7"
    readonly property color sideRing: Qt.rgba(1, 1, 1, 0.34)
    readonly property color sidePendingInk: "#91acac"
    readonly property color sideDoneInk: "#b8ddda"
    readonly property color sideText: "#b8ddda"
    readonly property color sideMuted: "#8ca9aa"               // .setup-side-foot
    readonly property color sideLead: "#b8d2d1"

    // 尺寸
    readonly property int radius: 7
    readonly property int windowW: 940
    readonly property int windowH: 650
    readonly property int windowMinW: 780
    readonly property int windowMinH: 540
    readonly property int titleBarH: 42
    readonly property int sideW: 228
    readonly property int contentPaddingH: 46
    readonly property int contentPaddingV: 40

    // 字体与字号
    readonly property string fontFamily: "Microsoft YaHei"
    readonly property int fontBody: 13
    readonly property int fontLead: 14
    readonly property int fontTitle: 23
    readonly property int fontSideTitle: 25                     // .setup-side h1
    readonly property int fontSmall: 12
    readonly property int fontFoot: 11                          // .setup-side-foot
    readonly property int fontButton: 13

    // 动效
    readonly property int animFast: 140
    readonly property int animNormal: 200
}
