// UninstallConfirmPage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Uninstall 2/3: confirmation + keep user data folder checkbox.
Item {
    id: page

    UiTheme { id: theme }
    width: theme.contentW
    height: theme.contentH
    property bool removeAllData: false
    property bool keepDataDir: false
    property string installDir: ""
    signal keepDataDirToggled(bool checked)
    signal backRequested()
    signal confirmRequested()

    readonly property string summary: (removeAllData
        ? qsTr("Program files will be removed and all OrbbecSlicer application data on this machine deleted: presets, calibration results, preferences, caches and credentials.")
        : qsTr("Program files will be removed; custom presets, calibration results, preferences and non-sensitive device info are kept; caches and login credentials are cleared."))
        + qsTr(" Files inside the install directory are deleted too, so keep personal projects outside it.")
        + (keepDataDir ? qsTr(" The user data folder created at install time is also kept.") : "")

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("Confirm uninstall")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.Bold
            color: theme.brand
        }
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.fillWidth: true
            text: qsTr("Confirm the data scope.")
            wrapMode: Text.WordWrap
            lineHeight: 1.5
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.textBody
        }

        Item { Layout.preferredHeight: 24 }

        // Summary of the selected scope: updates with the data scope and the "keep user data folder" checkbox.
        Text {
            Layout.fillWidth: true
            text: page.summary
            wrapMode: Text.WordWrap
            lineHeight: 1.65
            font.family: theme.fontFamily
            font.pixelSize: theme.fontBody
            color: theme.textBody
        }
        Item { Layout.preferredHeight: 14 }

        Rectangle {
            Layout.fillWidth: true
            Layout.maximumWidth: 560
            implicitHeight: safeCol.implicitHeight + 28
            radius: theme.radius
            color: theme.infoSoft
            border.width: 1
            border.color: theme.infoLine
            Column {
                id: safeCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14                       // .info-card padding: 14px 16px
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 4
                Item { width: 1; height: 2 }
                Text { text: qsTr("Not affected"); font.family: theme.fontFamily; font.pixelSize: theme.fontBody; font.bold: true; color: theme.infoInk }
                Text {
                    // Column does not pass width down: Text defaults to implicitWidth (the longest line),
                    // and without constraining it the card would be stretched to its maximum width.
                    width: safeCol.width
                    wrapMode: Text.WordWrap
                    lineHeight: 1.65
                    text: qsTr("Projects and exported files outside the program directory, plus cloud data for the current account.")
                    font.family: theme.fontFamily; font.pixelSize: theme.fontBody; color: theme.infoInk
                }
                Item {
                    implicitHeight: 30 + 4
                    implicitWidth: keepDataDirText.implicitWidth + 26
                    // Checkbox row (same layout as the check-row on the install options page: 16px checkbox + label starting at 24px),
                    // with 4px extra above to separate it from the description text.
                    function toggle() {
                        const v = !page.keepDataDir
                        page.keepDataDirToggled(v)
                    }
                    Rectangle {
                        width: 16; height: 16; radius: 3
                        anchors.verticalCenter: parent.verticalCenter
                        border.width: 1
                        border.color: page.keepDataDir ? theme.brand : theme.line
                        color: page.keepDataDir ? theme.brand : theme.panel
                        Text {
                            anchors.centerIn: parent
                            visible: page.keepDataDir
                            text: "✓"
                            color: theme.white
                            font.pixelSize: 11
                            font.bold: true
                        }
                    }
                    Text {
                        id: keepDataDirText
                        anchors.left: parent.left
                        anchors.leftMargin: 24
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Keep the user data folder")
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

        // Action row pinned to the bottom (design mockup .setup-actions { margin-top:auto; padding-top:22px });
        // .left-action is left-aligned, the remaining buttons are right-aligned.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: theme.btnGap
            UiBtn { text: qsTr("Back"); chevron: "left"; onClicked: page.backRequested() }
            Item { Layout.fillWidth: true }
            UiBtn {
                text: qsTr("Confirm uninstall")
                danger: true
                onClicked: page.confirmRequested()
            }
        }
    }
}
