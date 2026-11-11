// AppFrame.qml
import QtQuick

// Shell frame for the 11-11 design: 480px illustration panel on the left, content panel on the
// right with a 442px content column (18px left / 20px right inset, buttons 20px from the bottom).
// The design has no custom title bar and no step sidebar; the window is fixed at 960x540.
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
            // Content is laid out into the 442px column; anything wider is clipped instead of
            // spilling over the illustration or the window edge.
            clip: true
        }
    }

    // --- Window controls ---
    // A frameless window still needs minimize/close. They sit in the right panel's top-right
    // corner (outside the content column's title band) and stay visually quiet: grey glyphs that
    // only pick up a wash on hover.
    Row {
        id: windowButtons
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 6
        anchors.rightMargin: 8
        spacing: 2

        Repeater {
            model: frame.showMinimize ? ["minimize", "close"] : ["close"]
            delegate: Item {
                id: ctl
                required property string modelData
                width: 26
                height: 24
                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: ctlMa.containsMouse
                           ? (ctl.modelData === "close" ? theme.danger : theme.card)
                           : "transparent"
                    Behavior on color { ColorAnimation { duration: theme.animFast } }
                }
                Text {
                    anchors.centerIn: parent
                    text: ctl.modelData === "close" ? "×" : "−"
                    color: ctlMa.containsMouse && ctl.modelData === "close" ? theme.white : theme.mutedSoft
                    font.family: theme.fontFamily
                    font.pixelSize: ctl.modelData === "close" ? 16 : 15
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
