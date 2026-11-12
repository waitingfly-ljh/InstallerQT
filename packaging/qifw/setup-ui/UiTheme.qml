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
    // Page-level scroll handle (measured on 卸载 / 降级安装): 4px pill at x=948..951, i.e. in the
    // gutter outside the 442px content column.
    readonly property color scrollThumbPage: "#c4c4c4"
    readonly property color windowGlyph: "#868687"              // minimise / close glyphs (measured)
    readonly property color textFaint: "#a5a5a5"                // completion description (measured on 安装完成)
    readonly property color detailInk: "#a2a2a3"                // progress detail line (measured on 安装过程)
    // Completion disc (measured on 安装完成): vertical gradient #3bc3a5 → #119e90.
    readonly property color completeIconTop: "#3bc3a5"
    readonly property color completeIconBottom: "#119e90"
    // Tinted note inside the cards (measured on 确认卸载 / 卸载完成).
    readonly property color cardWarn: "#fff7e9"
    readonly property color cardWarnLine: "#f0d5a3"
    readonly property color cardBody: "#7c7d7e"                 // 12px body inside those cards
    // Uninstall scope page (measured on 卸载): unselected option card #fbfbfb with a #efefef border,
    // selected card #eef5f5 with the brand border, neutral table header #f9fcff / #d7eafe, and the
    // action chips - orange for "Delete" (#ffb163 on #fff4e8), grey for "Keep".
    readonly property color cardPlain: "#fbfbfb"
    readonly property color cardPlainLine: "#efefef"
    readonly property color cardSelected: "#eef5f5"
    readonly property color tableHeadBg: "#f9fcff"
    readonly property color tableHeadLine: "#d7eafe"
    readonly property color tableHeadInk: "#8e8f90"
    readonly property color rowInk: "#474f4f"
    readonly property color rowLine: "#f7f7f7"
    readonly property color rowLineSoft: "#f2f2f2"
    // Action pills in the uninstall table (measured on 卸载): orange = #FF8812 ink on the same hue at
    // 10%, grey = #ECECEC fill with #6B6B6C ink.
    readonly property color chipWarnBg: Qt.rgba(255 / 255, 136 / 255, 18 / 255, 0.10)
    readonly property color chipWarnInk: "#ff8812"
    readonly property color chipNeutralBg: "#ececec"
    readonly property color chipNeutralInk: "#6b6b6c"
    // 44px form field on the snapshot page (measured on 创建快照): 1px #f5f5f5 outline, 10px text
    // inset, and #b7b7b7 placeholder ink.
    readonly property color fieldOutline: "#f5f5f5"
    readonly property color textPlaceholder: "#b7b7b7"
    readonly property color inkDisabled: "#cccccc"              // disabled button label
    readonly property color checkLine: "#6b6b6c"                // unchecked checkbox border on the options page
    readonly property color checkLineStrong: "#009688"          // emphasised checkbox (license acceptance)
    readonly property color track: "#eeeeee"                    // progress track (design: #ECECEC, 12px rx6)
    // Design's progress fill fades horizontally from #009688 to the same hue at 10%.
    readonly property color trackFillEnd: Qt.rgba(0 / 255, 150 / 255, 136 / 255, 0.1)
    // Dialog backdrop (measured on 迁移失败 / 显示错误代码与重试): #0E1314 at 52%.
    readonly property color scrim: Qt.rgba(14 / 255, 19 / 255, 20 / 255, 0.52)
    readonly property color shadow: Qt.rgba(34 / 255, 34 / 255, 34 / 255, 0.2)

    // --- Dialog surfaces (measured on 迁移失败 / 显示错误代码与重试) ---
    readonly property color dialogEdge: "#dfdfdf"                // 1px card edge
    readonly property color dangerHeader: "#ff5c45"              // error dialog 53px header band
    readonly property color dangerHeaderInk: "#fafafa"           // band title
    readonly property color dialogClose: "#7c8282"               // dialog close glyph
    readonly property color dialogInk: "#474f4f"                 // step labels (measured on 迁移失败)
    readonly property color hairline: "#a6a6a6"                  // license card divider / muted rules
    readonly property color divider: Qt.rgba(166 / 255, 166 / 255, 166 / 255, 0.23)   // 1px row rule
    // Step connector inside the dialogs: #009688 fading into #1BF9E4 at 50% (measured on 迁移失败).
    readonly property color stepLineEnd: Qt.rgba(27 / 255, 249 / 255, 228 / 255, 0.5)
    readonly property color statusOk: "#00d941"                  // step status "done"
    readonly property color statusFail: "#f01c1c"                // step status "failed"
    // Snapshot dropdown overlay (measured on 创建快照-1/-2): 442x100 white 98% panel, 430x44 row at
    // 11% brand, secondary row ink #444444.
    readonly property color selectPanel: Qt.rgba(1, 1, 1, 0.98)
    readonly property color selectHighlight: Qt.rgba(0 / 255, 150 / 255, 136 / 255, 0.11)
    readonly property color selectRowInk: "#444444"

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
    // Measured on the frames: the title ink starts at y=41 on every page, and a 24px CJK line puts
    // its ink 5px below the text box, so the content column starts at y=36 (the old 18px value came
    // from an earlier, shorter header).
    readonly property int contentPaddingV: 36
    readonly property int panelBottom: 20
    readonly property real contentW: 442                        // 960 - artW - 18 - 20
    readonly property real contentH: 484                        // 540 - contentPaddingV(36) - panelBottom(20)

    readonly property int radius: 8
    readonly property int radiusBtn: 8
    // Fields: the install-location field is 443x33 rx6.5 (measured on 安装设置), the snapshot fields are
    // 441x43 rx9.5 (measured on 创建快照).
    readonly property real radiusFieldTight: 6.5
    readonly property real radiusSnapshotField: 9.5
    readonly property int radiusFieldBtn: 6                          // browse block inside the location field
    // Cards: 80px option / note cards are rx13.5 (measured on 卸载 / 确认卸载 / 创建快照).
    readonly property real radiusCard: 13.5
    // The license agreement card keeps its own 12px corners (measured on 许可协议).
    readonly property int radiusLicenseCard: 12
    // Version cards on the maintenance screens: outer 202x98 rx13.5 (radiusCard), inner 170x80 rx14.
    readonly property int radiusVersionCard: 14
    readonly property int radiusTag: 6                               // "推荐" pill 42x20
    readonly property int radiusDialog: 16
    // Window corner radius: every design frame's artboard is <rect width="960" height="540" rx="16">,
    // so the frameless window itself is rounded on all four corners, not just the cards.
    readonly property int windowRadius: 16
    readonly property int btnW: 124
    readonly property int btnH: 44
    readonly property int btnGap: 14
    // Dialog buttons hug their label: 取消 measures 92px in the failure / rollback dialogs.
    readonly property int btnHugW: 92
    // Checkboxes: option grid 17x17 rx4.5, license acceptance 16x16 rx4 (measured).
    readonly property int checkSize: 17
    readonly property int checkSizeStrong: 16
    readonly property real radiusCheck: 4.5
    readonly property int radiusCheckStrong: 4
    readonly property int checkLabelGap: 16
    // Radios (measured): snapshot page d25 ring + d18 dot, uninstall page d19 ring + d14 dot.
    readonly property int radioSizeLg: 25
    readonly property int radioDotLg: 18
    readonly property int radioSizeSm: 19
    readonly property int radioDotSm: 14
    readonly property int radioLabelGap: 9
    readonly property color radioRing: "#6b6b6c"               // unselected radio ring (measured)
    readonly property int optionCardH: 80
    readonly property int optionCardInkX: 45
    readonly property int tableHeadH: 40
    readonly property int tableRowH: 52
    readonly property int chipH: 32                                  // action pill measured 68x32 rx16
    readonly property int chipW: 68
    readonly property int chipRadius: 16
    readonly property int tagH: 20                                   // "推荐" pill inside an option card
    // Page scroll bar (measured on 卸载 / 降级安装): 4px wide, drawn in the gutter outside the content
    // column - x=948..951 in window coordinates, i.e. x=450 inside the page (content column starts at
    // 498), starting 4px below the content top and running to the content bottom.
    readonly property int scrollBarW: 4
    readonly property int scrollBarX: 450
    readonly property int scrollBarTop: 4
    // Content rhythm shared by all pages (design: title 20..44, lead 55..73, action rows 476..520).
    readonly property int fieldH: 33                                 // install-location field (measured 33)
    readonly property int snapshotFieldH: 43                         // snapshot page fields (measured 43)
    // Snapshot dropdown overlay (measured on 创建快照-1): 442x100 panel, 430x44 rows with 6px corners.
    readonly property int selectPanelW: 442
    readonly property int selectPanelH: 100
    readonly property int selectRowW: 430
    readonly property int selectRowH: 44
    readonly property int radiusPanel: 8
    readonly property int radiusSelectRow: 6
    // Dialogs. Skeleton A (rollback / migration failure, design: 回滚原程序和原配置 / 迁移失败):
    // a 560x428 content card whose bottom hosts a 560x84 footer strip; the footer buttons sit at
    // window y=427 (h44), i.e. 20px inside the strip, and the strip's bottom edge is window y=491.
    readonly property int dialogCardW: 560
    readonly property int dialogCardH: 428
    readonly property int dialogFooterH: 84
    readonly property int dialogBottomMargin: 49
    readonly property int dialogHeaderH: 72
    readonly property int dialogRowH: 47
    // Skeleton B (error code + retry, design: 显示错误代码与重试): 730x273 card with a 53px #FF5C45 band.
    readonly property int dialogErrorW: 730
    readonly property int dialogErrorH: 273
    readonly property int dialogErrorBand: 53

    // --- Fonts and font sizes ---
    // English uses a Western font; Chinese needs a font with CJK glyphs. The language is the
    // appLanguage context property injected by main.cpp; when it is absent (isolated tests) fall back to English.
    readonly property string fontFamily: (typeof appLanguage !== "undefined" && appLanguage === "zh_CN")
                                         ? "Microsoft YaHei" : "Segoe UI"
    readonly property int fontBody: 13                          // body ink 12..14 (measured em≈13)
    readonly property int fontLead: 13                          // page lead line (measured em≈13)
    readonly property int fontLabel: 14                         // field / option labels (measured em≈14)
    readonly property int fontSection: fontLabel                // section + card headings
    readonly property int fontTitle: 22                         // page titles (ink 22.8, em≈22)
    // Page titles are DemiBold in the design: ink density of "安装设置" is 62.0% in the frame against
    // 73.6% for Font.Bold, while the 16px body weight already matches.
    readonly property int fontTitleWeight: Font.DemiBold
    readonly property int fontWelcome: 22                       // welcome page lead line ("欢迎使用")
    readonly property int fontHero: 28                          // welcome product name / completion title (ink 28.9)
    readonly property int fontCardTitle: 18                     // license card heading (ink 19.1, em≈18)
    readonly property int fontCardInk: 16                       // option / note card headings (measured 16)
    readonly property int fontValue: fontCardInk                // version numbers, progress percentage
    readonly property int fontBodyLg: 15                        // dialog body, note-card heading (measured 15)
    readonly property int fontSmall: 12
    readonly property int fontHint: 12                          // "预计需要 1.8 GB 可用空间"
    readonly property int fontFoot: 11
    readonly property int fontButton: 13
    readonly property int fontChevron: 18                       // ‹ / › glyph next to a button label
    readonly property int fontCheck: 12                         // ✓ inside a checkbox / radio row
    readonly property int fontDialogTitle: 15                   // dialog header title
    readonly property int fontErrorBand: 13                     // title inside the red error band

    // --- Animation ---
    readonly property int animFast: 140
    readonly property int animNormal: 200
}
