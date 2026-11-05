// MaintenancePage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Maintenance page: repair / upgrade / downgrade. Downgrade requires acknowledging the risk before continuing.
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
    property string mode: "repair"           // repair | upgrade | downgrade
    property string currentVersion: ""
    property string targetVersion: ""
    property bool riskAcknowledged: false
    signal proceedRequested(mode: string)
    signal cancelRequested()
    signal riskToggled(bool checked)

    readonly property string title: mode === "repair" ? qsTr("Repair OrbbecSlicer")
                                  : mode === "upgrade" ? qsTr("Upgrade OrbbecSlicer")
                                  : qsTr("Downgrade OrbbecSlicer")
    readonly property string lead: mode === "repair"
        ? qsTr("The same version was detected. Repair rewrites the program files and keeps all user data.")
        : mode === "upgrade"
        ? qsTr("The new version will overwrite the existing program and migrate compatible local configuration.")
        : qsTr("The installer version is lower than the existing version. You can continue only after acknowledging the risk.")
    readonly property string primaryText: mode === "repair" ? qsTr("Start repair")
                                        : mode === "upgrade" ? qsTr("Start upgrade")
                                        : qsTr("Acknowledge and downgrade")
    readonly property var retained: [
        qsTr("Custom presets"), qsTr("Calibration results"), qsTr("Software preferences"),
        qsTr("Printer info"), qsTr("Account session"), qsTr("LAN access code")
    ]

    ColumnLayout {
        width: page.contentW
        height: page.contentH
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: page.title
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.DemiBold
            color: theme.text
        }
        // Lead copy (.setup-view .lead { margin: 9px 0 24px })
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.fillWidth: true
            text: page.lead
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            lineHeight: 1.7
            font.pixelSize: theme.fontLead
            color: theme.muted
        }
        Item { Layout.preferredHeight: 24 }

        // Design mockup .version-grid { grid-template-columns: 1fr 54px 1fr; gap: 10px; margin: 18px 0 }.
        // Fixed width (the content area width follows the window, and width: parent.width inside a Row cannot measure the content area).
        Row {
            Layout.topMargin: 18
            spacing: 10
            readonly property real boxW: 260
            width: 260 * 2 + 54 + 20
            Rectangle {
                width: parent.boxW
                implicitHeight: boxA.implicitHeight + 30
                radius: 6
                clip: true
                color: theme.panelSoft
                border.width: 1
                border.color: theme.line
                Column {
                    id: boxA
                    anchors.left: parent.left
                    width: parent.width - 30
                    anchors.leftMargin: 15
                    anchors.verticalCenter: parent.verticalCenter
                    Text { text: qsTr("Current version"); font.family: theme.fontFamily; font.pixelSize: theme.fontFoot; color: theme.muted }
                    Item { width: 1; height: 5 }
                    Text { text: page.currentVersion; font.family: theme.fontFamily; font.pixelSize: 18; font.bold: true; color: theme.text }
                }
            }
            Text {
                width: 54
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
                text: "→"
                font.family: theme.fontFamily
                font.pixelSize: 22
                color: theme.brand
            }
            Rectangle {
                width: parent.boxW
                implicitHeight: boxB.implicitHeight + 30
                radius: 6
                clip: true
                color: theme.panelSoft
                border.width: 1
                border.color: theme.line
                Column {
                    id: boxB
                    anchors.left: parent.left
                    width: parent.width - 30
                    anchors.leftMargin: 15
                    anchors.verticalCenter: parent.verticalCenter
                    Text { text: qsTr("Installer version"); font.family: theme.fontFamily; font.pixelSize: theme.fontFoot; color: theme.muted }
                    Item { width: 1; height: 5 }
                    Text { text: page.targetVersion; font.family: theme.fontFamily; font.pixelSize: 18; font.bold: true; color: theme.text }
                }
            }
        }

        // Retained list (.info-card + .retain-list two columns, ✓ prefix in the success color)
        Rectangle {
            Layout.topMargin: 18
            Layout.fillWidth: true
            implicitHeight: retain.implicitHeight + 28
            radius: theme.radius
            color: theme.infoSoft
            border.width: 1
            border.color: theme.infoLine
            Column {
                id: retain
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14
                spacing: 2
                Text {
                    text: qsTr("The following data will be kept")
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    font.bold: true
                    color: theme.textStrong
                }
                // Two columns (.retain-list { margin: 12px 0 0; grid-template-columns: 1fr 1fr; gap: 7px 14px })
                Grid {
                    width: parent.width
                    topPadding: 12
                    columns: 2
                    columnSpacing: 14
                    rowSpacing: 7
                    Repeater {
                        model: page.retained
                        delegate: Row {
                            required property string modelData
                            spacing: 7
                            height: 21
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "✓"
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                font.bold: true
                                color: theme.success
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                color: theme.textBody
                            }
                        }
                    }
                }
            }
        }

        Item {
            visible: page.mode === "downgrade"
            Layout.preferredHeight: 12
        }
        Rectangle {
            visible: page.mode === "downgrade"
            Layout.fillWidth: true
            implicitHeight: warnCol.implicitHeight + 24
            radius: theme.radius
            color: theme.warningSoft
            border.width: 1
            border.color: theme.warningLine
            Column {
                id: warnCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                spacing: 8
                Text { text: qsTr("Downgrading may cause configuration incompatibility"); font.family: theme.fontFamily; font.pixelSize: theme.fontBody; font.bold: true; color: theme.warningInk }
                Text {
                    wrapMode: Text.WordWrap
                    width: parent.width
                    text: qsTr("A recoverable snapshot is created before installation. Configuration the old version cannot read will be quarantined rather than overwritten.")
                    font.family: theme.fontFamily; font.pixelSize: theme.fontBody; color: theme.warningInk
                }
                Rectangle {
                    implicitHeight: 30
                    implicitWidth: riskAcknowledgedText.implicitWidth + 26
                    function toggle() {
                        const v = !page.riskAcknowledged
                        page.riskToggled(v)
                    }
                    Rectangle {
                        width: 16; height: 16; radius: 3
                        anchors.verticalCenter: parent.verticalCenter
                        border.width: 1
                        border.color: page.riskAcknowledged ? theme.brand : theme.line
                        color: page.riskAcknowledged ? theme.brand : theme.panel
                        Text {
                            anchors.centerIn: parent
                            visible: page.riskAcknowledged
                            text: "✓"
                            color: theme.white
                            font.pixelSize: 11
                            font.bold: true
                        }
                    }
                    Text {
                        id: riskAcknowledgedText
                        anchors.left: parent.left
                        anchors.leftMargin: 24
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("I understand the risk and want to install the older version")
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.text
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: parent.toggle()
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }

        // Action row pinned to the bottom (design mockup .setup-actions { margin-top:auto; padding-top:22px })
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            Item { Layout.fillWidth: true }
            UiBtn { text: qsTr("Cancel"); onClicked: page.cancelRequested() }
            UiBtn {
                text: page.primaryText
                primary: true
                enabledState: page.mode !== "downgrade" || page.riskAcknowledged
                onClicked: page.proceedRequested(page.mode)
            }
        }
    }
}
