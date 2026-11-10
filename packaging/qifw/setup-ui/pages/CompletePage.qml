// CompletePage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Complete page: completion icon + result copy + launch now.
// Also used for all three completion states: install, repair/upgrade/downgrade, and uninstall (title and button text are supplied externally).
Item {
    id: page

    // The page is drawn inside AppFrame's content area (size = window − title bar/side bar/padding). But the
    // parent size the page receives in this construction order is 0 (AppFrame's layout settles a step later, so the page's anchors.fill
    // is not recalculated), and the content area's ColumnLayout therefore lays out to the narrowest row (97px), wrapping
    // early wherever it would wrap. So the layout does not follow parent; it computes the content area from the window size directly. When the window size is unknown
    // (the hidden smoke copy) it falls back to the default 940×650.
    readonly property real contentW: (page.Window.width > 0 ? page.Window.width : theme.windowW)
                                     - theme.sideW - theme.contentPaddingH * 2
    readonly property real contentH: (page.Window.height > 0 ? page.Window.height : theme.windowH)
                                     - theme.titleBarH - theme.contentPaddingV - 24
    UiTheme { id: theme }
    property string title: qsTr("Installation complete")
    property string description: qsTr("OrbbecSlicer is ready.")
    property string primaryText: qsTr("Launch now")
    property bool showSecondary: false
    property string secondaryText: ""
    property bool launchEnabled: true
    signal primaryAction()
    signal secondaryAction()

    ColumnLayout {
        width: page.contentW
        height: page.contentH
        spacing: 0

        // Design mockup .complete-icon { margin: 34px auto 14px }—"34px" is the space above the icon; the whole
        // block is centered with .complete-copy inside the content area (equal flex space above and below), so the icon does not hug the page top.
        Item { Layout.fillHeight: true }
        Item {
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: 70; implicitHeight: 70 + 14          // 14 = height of the shadow overflowing downward

            // box-shadow: 0 10px 24px rgba(15,143,136,.22): rectangle + Gaussian blur, approximated by stacking two layers underneath
            // (the blur layer a bit fainter, so the edge is not a hard outline).
            // Shadow: concentric circles that fade outward, center 10px below the icon (box-shadow's y offset).
            Repeater {
                model: [
                    { "pad": 22, "dy": 12, "a": 0.04 },
                    { "pad": 16, "dy": 12, "a": 0.05 },
                    { "pad": 10, "dy": 11, "a": 0.06 },
                    { "pad": 5,  "dy": 10, "a": 0.06 }
                ]
                delegate: Rectangle {
                    required property var modelData
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: modelData.dy
                    width: 70 + modelData.pad * 2
                    height: width
                    radius: width / 2
                    color: theme.alpha(theme.brand, modelData.a)
                }
            }
            Rectangle {
                width: 70; height: 70; radius: 35
                color: theme.brand
                Text {
                    anchors.centerIn: parent
                    text: "✓"
                    color: theme.white
                    font.family: theme.fontFamily
                    font.pixelSize: 34
                }
            }
        }
        Item { Layout.preferredHeight: 14 }
        Text {
            Layout.alignment: Qt.AlignHCenter
            horizontalAlignment: Text.AlignHCenter
            text: page.title
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle + 1           // .complete-copy h2: 24px
            font.weight: Font.DemiBold
            color: theme.text
        }
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.alignment: Qt.AlignHCenter
            horizontalAlignment: Text.AlignHCenter
            text: page.description
            wrapMode: Text.WordWrap
            lineHeight: 1.7
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.muted
        }

        Item { Layout.fillHeight: true }

        // Action row pinned to the bottom (design mockup .setup-actions { margin-top:auto; padding-top:22px })
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            Item { Layout.fillWidth: true }
            UiBtn {
                visible: page.showSecondary
                text: page.secondaryText
                onClicked: page.secondaryAction()
            }
            UiBtn {
                text: page.primaryText
                primary: true
                enabledState: page.launchEnabled
                onClicked: page.primaryAction()
            }
        }
    }
}
