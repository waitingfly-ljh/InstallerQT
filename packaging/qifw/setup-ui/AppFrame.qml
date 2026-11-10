// AppFrame.qml
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import SetupUi

// Shell frame: 42px custom title bar + 228px dark sidebar + content area.
// Pages attach to the content area through the default property content.
Item {
    id: frame
    UiTheme { id: theme }

    signal minimizeRequested()
    signal closeRequested()
    signal stepClicked(int index)

    property string windowTitle: qsTr("OrbbecSlicer Setup Wizard")
    property string sideHeadline: qsTr("Let creativity\ntake shape")
    property string sideFoot: qsTr("OrbbecSlicer %1").arg(Host.version)
    // install | uninstall: uninstall uses its own three-step list (data scope -> confirm -> complete)
    property string style: "install"
    property var installSteps: []
    property var uninstallSteps: []
    property int currentStep: 0
    property bool showMinimize: true
    readonly property var steps: style === "uninstall" ? uninstallSteps : installSteps
    default property alias content: contentHost.data

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // --- Title bar ---
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: theme.titleBarH
            color: theme.topbar
            // Bottom border of the design mockup .setup-titlebar (1px, within the 42px)
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                        height: 1; color: theme.titleLine }
            // The title bar drag area covers the whole title bar; when an input field on the page scrolls here, wheel events bubble
            // up the parent chain to the drag area — if not intercepted, they are treated as "dragging the window", no position changes are received during the drag,
            // and the window suddenly jumps away on release. So the wheel is ignored directly here.
            WheelHandler { onWheel: (e) => { e.accepted = true } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 0
                spacing: 9

                BrandMark { Layout.alignment: Qt.AlignVCenter; base: theme.brand; accent: theme.brandSoft }

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: frame.windowTitle
                    color: theme.titleText
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                }
                Item { Layout.fillWidth: true }

                // Minimize
                Item {
                    Layout.preferredWidth: 46
                    Layout.fillHeight: true
                    visible: frame.showMinimize
                    Rectangle {
                        anchors.fill: parent
                        color: minMa.containsMouse ? theme.titleHover : "transparent"
                        Behavior on color { ColorAnimation { duration: theme.animFast } }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "−"
                        color: theme.titleMuted
                        font.pixelSize: 16
                    }
                    MouseArea {
                        id: minMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: frame.minimizeRequested()
                    }
                }

                // Close
                Item {
                    Layout.preferredWidth: 46
                    Layout.fillHeight: true
                    Rectangle {
                        anchors.fill: parent
                        color: closeMa.containsMouse ? theme.danger : "transparent"
                        Behavior on color { ColorAnimation { duration: theme.animFast } }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: closeMa.containsMouse ? theme.white : theme.titleMuted
                        font.pixelSize: 16
                    }
                    MouseArea {
                        id: closeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: frame.closeRequested()
                    }
                }
            }

            // Title bar drag
            MouseArea {
                anchors.fill: parent
                anchors.rightMargin: 92
                property point pressPos
                onPressed: (m) => pressPos = Qt.point(m.x, m.y)
                onPositionChanged: (m) => {
                    if (!pressed)
                        return
                    // Walk up from the MouseArea to the owning Window; do not depend on a specific id.
                    const w = frame.Window.window
                    if (w) {
                        w.x += m.x - pressPos.x
                        w.y += m.y - pressPos.y
                    }
                }
            }
        }

        // --- Body --- sidebar | content area
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // Sidebar
            Rectangle {
                id: sideArea
                Layout.preferredWidth: theme.sideW
                Layout.fillHeight: true
                clip: true
                // The layout reparents its children onto itself; the glow and text column in the sidebar are therefore explicitly pinned to sideArea,
                // otherwise anchors.fill: parent would attach to the layout, and sizes and padding would be lost.
                // Background color of the design mockup .setup-side: linear-gradient(175deg, sideTop 0%, sideMid 58%, sideBottom 100%)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: theme.sideTop }
                    GradientStop { position: 0.58; color: theme.sideMid }
                    GradientStop { position: 1.0; color: theme.sideBottom }
                }
                // Top-left glow: radial-gradient(circle at 10% 18%, rgba(55,192,184,.35), transparent 35%).
                // Qt only has linear gradients, so the radial one is drawn with an Image: resources/glow.png is a pre-generated 228×300 image
                // (formula in SideGlow.qml), stretched to the sidebar's actual size.
                Image {
                    parent: sideArea
                    anchors.fill: parent
                    source: "qrc:/glow.png"
                    fillMode: Image.Stretch
                    smooth: true
                    opacity: 0.5
                }

                ColumnLayout {
                    // Design mockup .setup-side { padding: 34px 24px }; the bottom version number is pinned 24px from the bottom separately.
                    parent: sideArea
                    anchors.fill: parent
                    anchors.leftMargin: 24
                    anchors.rightMargin: 24
                    anchors.topMargin: 34
                    anchors.bottomMargin: 24
                    spacing: 0

                    Text {
                        text: frame.sideHeadline
                        color: theme.white
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSideTitle
                        font.bold: true
                        lineHeight: 1.4
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    Item { Layout.preferredHeight: 30 }

                    StepList {
                        Layout.fillWidth: true
                        steps: frame.steps
                        Component.onCompleted: stepClicked.connect((i) => frame.stepClicked(i))
                    }

                    Item { Layout.fillHeight: true }

                    Text {
                        text: frame.sideFoot
                        color: theme.sideMuted
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontFoot
                        lineHeight: 1.6
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }
                }
            }

            // Content area (design mockup .setup-main background: white)
            Rectangle {
                id: contentArea
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: theme.surface

                Item {
                    id: contentHost
                    // Same as above: pinned uniformly to the content area rectangle, not the layout.
                    parent: contentArea
                    anchors.fill: parent
                    anchors.leftMargin: theme.contentPaddingH
                    anchors.rightMargin: theme.contentPaddingH
                    anchors.topMargin: theme.contentPaddingV
                    anchors.bottomMargin: 24
                }
            }
        }
    }
}
