// UiTheme.qml
// Single source of truth for visual tokens: values are taken from the :root variables of
// the design mockup OrbbecSlicer_安装与首次设置_交互原型.html.
// Every page reads colors and sizes from here instead of hardcoding color values per page
// (derived colors and status inks are centralized here as well).
//
// Why a plain (non-singleton) QtObject: this project loads the module through an absolute
// qrc path (Qt 6.8.3). A singleton would have to read qmldir to know it is a singleton, but
// qmldir is not loaded yet when the module root object is instantiated, so it would be
// created as a plain component, every Theme.xxx would be undefined, and no error would be
// raised. As a plain component, each file writes `UiTheme { id: theme }` and reads values
// through property bindings, independent of module resolution order.
//
// Why not named Theme: qt_add_qml_module skips type names ending in "Theme" during type
// registration, while component files (UiBtn, etc.) rely on the type names provided by the
// root qmldir to resolve the token table. With the Ui prefix, both the token table and the
// control components live at the module root, and pages simply `import SetupUi`.
//
// Note: each token is written as a literal exactly once here; derived colors reference
// literals from this same table; never let a token reference itself (e.g.
// `white: theme.white`), or Qt reports a Binding loop and yields undefined.
import QtQuick

QtObject {
    // Brand and neutral colors
    readonly property color brand: "#0f8f88"
    readonly property color brandDark: "#0d6f6a"
    readonly property color brandSoft: "#e8f7f5"
    // Border color of .button:hover in the mockup (more saturated than brandLine, used on button hover)
    readonly property color brandHoverLine: "#8acbc6"
    readonly property color brandLine: "#c3e6e2"
    readonly property color topbar: "#273438"
    readonly property color page: "#f3f5f6"                    // backdrop outside the page (--page)
    readonly property color surface: "#ffffff"                 // content area (mockup .setup-main background: #fff)
    readonly property color panel: "#ffffff"
    readonly property color line: "#dfe4e7"
    readonly property color lineSoft: "#edf0f2"
    readonly property color text: "#263238"
    readonly property color textStrong: "#26383a"              // card titles (.status-card strong etc.)
    readonly property color textBody: "#47585b"                // .retain-item
    readonly property color panelSoft: "#fafbfb"               // .version-box background
    readonly property color track: "#e9eeef"                   // .progress-track
    readonly property color trackFillEnd: "#49c4bb"            // .progress-fill gradient end
    readonly property color muted: "#7a878d"
    readonly property color white: "#ffffff"

    // Status colors
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

    // Interaction-derived colors
    readonly property color brandHover: "#0e8079"
    // Brand highlight on the dark sidebar (brandDark is nearly invisible on dark backgrounds; use a brighter teal)
    readonly property color brandAccent: "#3fd0c4"
    readonly property color sideGlow: Qt.rgba(55 / 255, 192 / 255, 184 / 255, 0.35)  // sidebar top-left glow
    readonly property color titleText: "#e9eef0"
    readonly property color titleMuted: "#d5dde0"
    readonly property color titleLine: "#151d1f"              // title bar bottom border
    readonly property color titleHover: Qt.rgba(1, 1, 1, 0.10) // .window-btn:hover

    // Apply an alpha value to a token (for shadows and other places that need the same hue at a different strength).
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    // Dark sidebar gradient (mockup .setup-side)
    // 175deg: top-left #184c4b -> #143c3e at 58% -> bottom-right #172d32; a radial glow from the
    // top-left is layered on top (see AppFrame).
    readonly property color sideTop: "#184c4b"
    readonly property color sideMid: "#143c3e"
    readonly property color sideBottom: "#172d32"
    readonly property color sideActiveDot: "#0f8f88"           // .step-item.active .step-dot background
    readonly property color sideActiveRing: "#63d7d0"
    readonly property color sideDoneDot: Qt.rgba(15 / 255, 143 / 255, 136 / 255, 0.38)
    readonly property color sideDoneRing: "#79bcb7"
    readonly property color sideRing: Qt.rgba(1, 1, 1, 0.34)
    readonly property color sidePendingInk: "#91acac"
    readonly property color sideDoneInk: "#b8ddda"
    readonly property color sideText: "#b8ddda"
    readonly property color sideMuted: "#8ca9aa"               // .setup-side-foot
    readonly property color sideLead: "#b8d2d1"

    // Dimensions
    readonly property int radius: 7
    readonly property int windowW: 940
    readonly property int windowH: 650
    readonly property int windowMinW: 780
    readonly property int windowMinH: 540
    readonly property int titleBarH: 42
    readonly property int sideW: 228
    readonly property int contentPaddingH: 46
    readonly property int contentPaddingV: 40

    // Fonts and font sizes
    readonly property string fontFamily: "Microsoft YaHei"
    readonly property int fontBody: 13
    readonly property int fontLead: 14
    readonly property int fontTitle: 23
    readonly property int fontSideTitle: 25                     // .setup-side h1
    readonly property int fontSmall: 12
    readonly property int fontFoot: 11                          // .setup-side-foot
    readonly property int fontButton: 13

    // Animation
    readonly property int animFast: 140
    readonly property int animNormal: 200
}
