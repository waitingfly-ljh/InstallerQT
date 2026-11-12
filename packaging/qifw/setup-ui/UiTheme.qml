// UiTheme.qml
// Single source of truth for visual tokens. Values come from the 11-11 installer design
// (Figma file Mc0tBFqnQRh4b2UU4GojRw, canvas "新增（11-11）", node 7650:5224):
//   left illustration panel 480px + right content panel 480px, content column 442px (18px left /
//   20px right inset), brand teal #009688, 24px bold titles, 14px body, 124x44 buttons, radius 8/12/16.
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
    // --- Brand ---
    readonly property color brand: "#009688"
    readonly property color brandDark: "#00796b"                // primary button hover / pressed
    readonly property color brandHoverLine: "#4db6ac"           // secondary button hover border
    readonly property color brandLine: "#b2dfdb"
    readonly property color brandSoft: "#e0f2f1"
    // Teal wash used by the dialog hint strip and the "1.8 GB" accent (design: rgba(0,150,136,.05)).
    readonly property color brandWash: Qt.rgba(0 / 255, 150 / 255, 136 / 255, 0.05)

    // --- Neutrals ---
    readonly property color white: "#ffffff"
    readonly property color page: "#ffffff"                     // window backdrop
    readonly property color surface: "#ffffff"                  // right content panel
    readonly property color panel: "#ffffff"                    // input fields, secondary buttons
    readonly property color panelSoft: "#fafbfb"                // version boxes / soft blocks
    readonly property color card: "#f5f5f5"                     // cards (input fields, soft blocks)
    readonly property color cardAlt: "#eeeeee"                  // license agreement card
    readonly property color cardTeal: "#f2faf9"                 // tinted card (design: "安装包版本" box)
    readonly property color cardBlue: "#f9fcff"                 // tinted card (design: data-retention box)
    readonly property color cardBlueLine: "#9acdff"             // 1px border of the data-retention card (measured)
    readonly property color btnSecondary: "#fbfbfb"             // secondary button fill (measured on every frame)
    readonly property color btnSecondaryLine: "#ececec"         // secondary button 1px border
    readonly property color btnDisabled: "#cccccc"              // disabled primary fill (design: #cccccc + light label)
    readonly property color btnDisabledInk: "#eeeeee"
    readonly property color fieldLine: "#d7d7d7"                // install-location field border (measured)
    readonly property color fieldBtn: "#e9e9e9"                 // browse button inside the field (measured)
    readonly property color line: "#e0e0e0"
    readonly property color lineSoft: "#eeeeee"
    readonly property color text: "#222222"
    readonly property color textStrong: "#262e30"
    readonly property color textBody: "#6b6b6c"
    readonly property color muted: "#757575"
    readonly property color mutedSoft: "#bdbdbd"                // dialog pending rows / window buttons
    readonly property color scrollThumb: "#bababa"              // license card scroll handle (measured on the 许可协议 frame)
    readonly property color inkDisabled: "#cccccc"              // disabled button label
    readonly property color checkLine: "#6b6b6c"                // unchecked checkbox border on the options page
    readonly property color checkLineStrong: "#009688"          // emphasised checkbox (license acceptance)
    readonly property color track: "#eeeeee"                    // progress track
    readonly property color trackFillEnd: "#26a69a"             // progress fill gradient end
    readonly property color scrim: Qt.rgba(0 / 255, 0 / 255, 0 / 255, 0.5)   // dialog backdrop
    readonly property color shadow: Qt.rgba(34 / 255, 34 / 255, 34 / 255, 0.2)

    // --- Status ---
    readonly property color danger: "#ff5038"                   // measured: dialog title + failed dot
    readonly property color dangerSoft: "#fff1f0"
    readonly property color dangerLine: "#ffccc7"
    readonly property color dangerInk: "#e03a24"
    readonly property color warning: "#fa8c16"
    readonly property color warningSoft: "#fff7e6"
    readonly property color warningLine: "#ffd591"
    readonly property color warningInk: "#874d00"
    readonly property color success: "#52c41a"
    readonly property color successSoft: "#f6ffed"
    readonly property color successLine: "#d9f7be"
    readonly property color successInk: "#389e0d"
    readonly property color info: "#1890ff"
    readonly property color infoSoft: "#e6f7ff"
    readonly property color infoLine: "#91d5ff"
    readonly property color infoInk: "#0050b3"

    // Apply an alpha value to a token (for shadows and other places that need the same hue at a different strength).
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    // --- Dimensions (design is a fixed 960x540 window) ---
    readonly property int windowW: 960
    readonly property int windowH: 540
    readonly property int windowMinW: 960
    readonly property int windowMinH: 540
    // Left illustration panel; the right content panel takes the rest.
    readonly property int artW: 480
    // Measured on the design frames: the content column starts 18px into the right panel and ends
    // 20px before the window edge (buttons line up with x=940), so it is 442px wide.
    readonly property int contentPaddingH: 20
    readonly property int contentPaddingLeft: 18
    readonly property int contentPaddingV: 18
    readonly property int panelBottom: 20
    readonly property real contentW: 442                        // 960 - artW - 18 - 20
    readonly property real contentH: 502                        // 540 - contentPaddingV - panelBottom

    readonly property int radius: 8
    readonly property int radiusBtn: 8
    readonly property int radiusField: 8
    readonly property int radiusCard: 12
    readonly property int radiusDialog: 16
    readonly property int btnW: 124
    readonly property int btnH: 44
    readonly property int btnGap: 14
    readonly property int checkSize: 18
    readonly property int checkLabelGap: 16
    // Content rhythm shared by all pages (design: title 20..44, lead 55..73, action rows 476..520).
    readonly property int fieldH: 34
    // Error dialog (measured on the 配置迁移失败 frame): 558px wide (the frame's 4 steps make it 427px
    // tall; the shell renders the engine's real phases), 21px side padding, 13px bottom padding,
    // 79px header, 47px step rows. Inside a row: icon 12..30, label 41, divider 43..edge,
    // status centred in a 98px cell, hint strip 62px with a 16px badge inset 15px from the top.
    readonly property int dialogW: 558
    readonly property int dialogPad: 21
    readonly property int dialogPadBottom: 13
    readonly property int dialogHeaderH: 79
    readonly property int dialogRowH: 47

    // --- Fonts and font sizes ---
    // English uses a Western font; Chinese needs a font with CJK glyphs. The language is the
    // appLanguage context property injected by main.cpp; when it is absent (isolated tests) fall back to English.
    readonly property string fontFamily: (typeof appLanguage !== "undefined" && appLanguage === "zh_CN")
                                         ? "Microsoft YaHei" : "Segoe UI"
    readonly property int fontBody: 14
    readonly property int fontLead: 16                          // page lead line (measured on 安装设置 / 升级)
    readonly property int fontSection: 16                       // section label ("安装位置")
    readonly property int fontTitle: 24
    readonly property int fontWelcome: 24                       // welcome page lead line ("欢迎使用")
    readonly property int fontHero: 30                          // welcome page product name
    readonly property int fontCardTitle: 20                     // license card heading (measured)
    readonly property int fontSmall: 12
    readonly property int fontHint: 14                          // "预计需要 1.8 GB 可用空间"
    readonly property int fontFoot: 11
    readonly property int fontButton: 14

    // --- Animation ---
    readonly property int animFast: 140
    readonly property int animNormal: 200
}
