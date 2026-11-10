// FailurePage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Install incomplete page: rollback explanation + diagnostics + view logs / try again.
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
    property string rollbackTitle: qsTr("Original version and configuration restored")
    property string rollbackText: qsTr("Program files have been rolled back to the original version and the configuration snapshot passed verification. You can keep using the original version or try installing again.")
    property string errorCode: ""
    property string errorText: ""
    property string logPath: Host.logPath
    signal openLogsRequested()
    signal retryRequested()

    ColumnLayout {
        width: page.contentW
        height: page.contentH
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("Installation incomplete")
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
            text: qsTr("An error occurred while writing the new version, so subsequent operations were stopped.")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            lineHeight: 1.7
            font.pixelSize: theme.fontLead
            color: theme.muted
        }
        Item { Layout.preferredHeight: 24 }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: okCol.implicitHeight + 28
            radius: theme.radius
            color: theme.successSoft
            border.width: 1
            border.color: theme.successLine
            Column {
                id: okCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14                       // .info-card / .success-card padding: 14px 16px
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 4
                Text { text: page.rollbackTitle; font.family: theme.fontFamily; font.pixelSize: theme.fontBody; font.bold: true; color: theme.successInk }
                Text {
                    wrapMode: Text.WordWrap
                    width: parent.width
                    text: page.rollbackText
                    lineHeight: 1.65                     // Unified card line-height: 1.65
                    font.family: theme.fontFamily; font.pixelSize: theme.fontBody; color: theme.successInk
                }
            }
        }

        Item { Layout.preferredHeight: 12 }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: diagCol.implicitHeight + 28
            radius: theme.radius
            color: theme.infoSoft
            border.width: 1
            border.color: theme.infoLine
            Column {
                id: diagCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14                       // .info-card / .success-card padding: 14px 16px
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 4
                Text { text: qsTr("Diagnostics"); font.family: theme.fontFamily; font.pixelSize: theme.fontBody; font.bold: true; color: theme.infoInk }
                Text {
                    wrapMode: Text.WordWrap
                    width: parent.width
                    text: {
                        const code = page.errorCode.length ? qsTr("Error code INS-%1").arg(page.errorCode) : qsTr("Error code unknown")
                        return page.errorText.length ? code + ", " + page.errorText : code
                    }
                    lineHeight: 1.65
                    font.family: theme.fontFamily; font.pixelSize: theme.fontBody; color: theme.infoInk
                }
                Text {
                    width: parent.width
                    elide: Text.ElideMiddle
                    text: qsTr("Log: %1").arg(page.logPath)
                    font.family: theme.fontFamily; font.pixelSize: theme.fontSmall; color: theme.infoInk
                }
            }
        }

        Item { Layout.fillHeight: true }

        // Action row pinned to the bottom (design mockup .setup-actions { margin-top:auto; padding-top:22px })
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            UiBtn {
                text: qsTr("Open logs")
                onClicked: page.openLogsRequested()
            }
            Item { Layout.fillWidth: true }
            UiBtn {
                text: qsTr("Try again")
                primary: true
                onClicked: page.retryRequested()
            }
        }
    }
}
