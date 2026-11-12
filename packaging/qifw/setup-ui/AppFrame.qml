// AppFrame.qml
import QtQuick
import QtQuick.Effects

// Shell frame for the 11-11 design: 480px illustration panel on the left, content panel on the
// right with a 442px content column (18px left / 20px right inset, buttons 20px from the bottom).
// The design has no custom title bar and no step sidebar; the window is fixed at 960x540 and its
// artboard is rounded with rx=16 on all four corners, so the whole shell is clipped to that shape.
//
// Pages are injected through `content` (a list): AppFrame { content: [ StackLayout { ... } ] }.
// It is deliberately NOT the default property: a default alias would also capture this file's own
// children (the illustration, the panel, the window buttons), which then land inside the page host
// instead of being drawn. Keeping the alias explicit keeps the chrome a real visual child.
Item {
    id: frame
    UiTheme { id: theme }

    signal minimizeRequested()
    signal closeRequested()

    property string windowTitle: qsTr("OrbbecSlicer Setup Wizard")
    property bool showMinimize: true
    // Page host: the content column (442px wide, inset from the right panel). Children assigned here
    // are added to contentHost's data, so `anchors.fill: parent` resolves to the content column.
    property alias content: contentHost.data

    // --- Rounded surface ---
    // The window is frameless, and neither Windows (Win10 does not round frameless windows) nor
    // QML's rectangular `clip` rounds it, so the design's 16px corners come from a mask: the
    // surface is rendered through a MultiEffect whose mask source is a white rounded rectangle.
    // The mask's alpha cuts the illustration and the right panel into the same shape on all four
    // sides. The window itself is transparent (see Main.qml), otherwise the corners would show the
    // window background instead of the desktop.
    Item {
        id: surface
        anchors.fill: parent
        // The mask is a shader effect (MultiEffect). Qt's software scene-graph backend — the
        // screenshot harness (QT_QUICK_BACKEND=software) and machines without a usable GPU — cannot
        // render it and would leave the whole window blank, so there the shell stays unmasked: the
        // corners are square but the layout is real. Rounding is verified on a live window instead.
        layer.enabled: GraphicsInfo.api !== GraphicsInfo.Software
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: surfaceMask
        }

        // Base fill: the illustration covers the left panel, but the surface stays painted anyway
        // so a still-loading image can never leave a transparent hole inside the frame.
        Rectangle {
            anchors.fill: parent
            color: theme.page
        }

        // --- Left illustration panel (design: 0..480, full height) ---
        Image {
            id: art
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: theme.artW
            source: "qrc:/wizard-art.jpg"
            // The source is 960x1080 (2x of the 480x540 panel), so the aspect ratio already matches
            // and PreserveAspectCrop covers the panel without cropping any of the illustration.
            fillMode: Image.PreserveAspectCrop
            smooth: true
            // Drag area for the frameless window: the illustration is the only region without controls,
            // so the whole panel is used to move the window (same behaviour as the old title bar).
            MouseArea {
                anchors.fill: parent
                property point pressPos
                onPressed: (m) => pressPos = Qt.point(m.x, m.y)
                onPositionChanged: (m) => {
                    if (!pressed)
                        return
                    const w = frame.Window.window
                    if (w) {
                        w.x += m.x - pressPos.x
                        w.y += m.y - pressPos.y
                    }
                }
            }
        }

        // --- Right content panel ---
        Rectangle {
            id: panel
            anchors.left: art.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            color: theme.surface

            Item {
                id: contentHost
                anchors.fill: parent
                anchors.leftMargin: theme.contentPaddingLeft
                anchors.rightMargin: theme.contentPaddingH
                anchors.topMargin: theme.contentPaddingV
                anchors.bottomMargin: theme.panelBottom
                // No clip here: the page-level scroll bar sits in the gutter to the right of the
                // 442px column (design x=948..951) and has to stay visible. Pages constrain their
                // own text width, and the columns that can overflow use their own clip.
                clip: false
            }
        }
    }

    // Mask source for the rounded surface: white rounded rectangle, rendered into its own layer so
    // MultiEffect can sample its alpha. Not visible itself.
    Item {
        id: surfaceMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        Rectangle {
            anchors.fill: parent
            radius: theme.windowRadius
            color: "white"
        }
    }

    // --- Window controls ---
    // A frameless window still needs minimize/close. Measured on the frames: a 16x2 dash centred at
    // (877.5, 19.5) and a 12x12 cross centred at (931.5, 19.5), i.e. 54px apart and 28.5px in from
    // the right edge, drawn in #868687. The glyphs are shapes (not "−"/"×" text) so the stroke size
    // does not follow the font size.
    Row {
        id: windowButtons
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 6
        anchors.rightMargin: 15
        spacing: 28

        Repeater {
            model: frame.showMinimize ? ["minimize", "close"] : ["close"]
            delegate: Item {
                id: ctl
                required property string modelData
                width: 26
                height: 26
                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: ctlMa.containsMouse
                           ? (ctl.modelData === "close" ? theme.danger : theme.card)
                           : "transparent"
                    Behavior on color { ColorAnimation { duration: theme.animFast } }
                }
                readonly property color ink: ctlMa.containsMouse && ctl.modelData === "close"
                                              ? theme.white : theme.windowGlyph

                // Minimise: 16x2 rounded dash.
                Rectangle {
                    visible: ctl.modelData === "minimize"
                    anchors.centerIn: parent
                    width: 16
                    height: 2
                    radius: 1
                    color: ctl.ink
                }
                // Close: 12x12 cross built from two 2px diagonal strokes.
                Item {
                    visible: ctl.modelData === "close"
                    anchors.centerIn: parent
                    width: 12
                    height: 12
                    Rectangle {
                        anchors.centerIn: parent
                        width: 2
                        height: 16
                        radius: 1
                        rotation: 45
                        color: ctl.ink
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 2
                        height: 16
                        radius: 1
                        rotation: -45
                        color: ctl.ink
                    }
                }
                MouseArea {
                    id: ctlMa
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: ctl.modelData === "close" ? frame.closeRequested() : frame.minimizeRequested()
                }
            }
        }
    }
}
