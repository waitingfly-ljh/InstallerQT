// DataScopePage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Uninstall 1/3: choose the data scope. Defaults to "Keep personal data"; the category table changes with the selection.
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
    property bool removeAllData: false
    property bool keepDataDir: false
    signal modeSelected(bool removeAll)
    signal nextRequested()
    signal cancelRequested()

    readonly property var dataRows: removeAllData
        ? [
            { "name": qsTr("Custom presets, calibration results"), "action": qsTr("Delete"), "isDelete": true },
            { "name": qsTr("Software preferences, regional settings"), "action": qsTr("Delete"), "isDelete": true },
            { "name": qsTr("Caches and logs"), "action": qsTr("Delete"), "isDelete": true },
            { "name": qsTr("Login tokens, cloud service credentials"), "action": qsTr("Delete"), "isDelete": true },
            { "name": qsTr("Project files outside the install directory"), "action": qsTr("Keep"), "isDelete": false }
        ]
        : [
            { "name": qsTr("Custom presets, calibration results"), "action": qsTr("Keep"), "isDelete": false },
            { "name": qsTr("Software preferences, regional settings"), "action": qsTr("Keep"), "isDelete": false },
            { "name": qsTr("Caches and logs"), "action": qsTr("Delete"), "isDelete": true },
            { "name": qsTr("Login tokens, cloud service credentials"), "action": qsTr("Delete"), "isDelete": true },
            { "name": qsTr("Project files outside the install directory"), "action": qsTr("Keep"), "isDelete": false }
        ]

    ColumnLayout {
        width: page.contentW
        height: page.contentH
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("What should happen to personal data?")
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
            text: qsTr("Choose the data scope for this machine.")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            lineHeight: 1.7
            font.pixelSize: theme.fontLead
            color: theme.muted
        }
        Item { Layout.preferredHeight: 24 }

        // Two data scope options: defaults to "Keep personal data" (removeAllData=false).
        Column {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: [
                    { "removeAll": false,
                      "title": qsTr("Keep personal data"),
                      "detail": qsTr("Presets, calibration results, preferences and device info are kept; caches and login credentials are cleared.") },
                    { "removeAll": true,
                      "title": qsTr("Delete all application data on this machine"),
                      "detail": qsTr("Presets, calibration results, preferences and device info are deleted as well.") }
                ]
                delegate: Rectangle {
                    id: optionCard
                    required property var modelData
                    readonly property bool selected: page.removeAllData === modelData.removeAll
                    width: tableColumn ? tableColumn.width : 0
                    implicitHeight: optionRow.implicitHeight + 20
                    radius: theme.radius
                    color: selected ? theme.brandSoft : theme.panel
                    border.width: 1
                    border.color: selected ? theme.brand : theme.line

                    Row {
                        id: optionRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10

                        Rectangle {
                            width: 16
                            height: 16
                            radius: 8
                            anchors.verticalCenter: parent.verticalCenter
                            border.width: 1
                            border.color: optionCard.selected ? theme.brand : theme.line
                            color: theme.panel
                            Rectangle {
                                anchors.centerIn: parent
                                width: 8
                                height: 8
                                radius: 4
                                visible: optionCard.selected
                                color: theme.brand
                            }
                        }
                        Column {
                            width: optionRow.width - 26
                            spacing: 2
                            Text {
                                text: optionCard.modelData.title
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                font.bold: true
                                color: theme.text
                            }
                            Text {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: optionCard.modelData.detail
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontSmall
                                color: theme.muted
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            page.removeAllData = optionCard.modelData.removeAll
                            page.modeSelected(optionCard.modelData.removeAll)
                        }
                    }
                }
            }
        }
        Item { Layout.preferredHeight: 14 }

        // Data category table: plain Column + Repeater, to avoid a custom component with Row properties.
        Rectangle {
            id: tableColumn
            Layout.fillWidth: true
            implicitHeight: tableCol.implicitHeight + 20
            Layout.preferredHeight: implicitHeight
            radius: theme.radius
            color: theme.panel
            border.width: 1
            border.color: theme.line

            Column {
                id: tableCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 10
                spacing: 0

                Item {
                    width: parent.width
                    height: 26
                    Text {
                        width: parent.width * 0.68
                        text: qsTr("Data")
                        font.family: theme.fontFamily; font.pixelSize: theme.fontSmall
                        font.bold: true; color: theme.muted
                    }
                    Text {
                        x: parent.width * 0.68
                        width: parent.width * 0.32
                        text: page.removeAllData ? qsTr("Delete all") : qsTr("Default uninstall")
                        font.family: theme.fontFamily; font.pixelSize: theme.fontSmall
                        font.bold: true; color: theme.muted
                    }
                }

                Repeater {
                    model: page.dataRows
                    delegate: Item {
                        id: rowItem
                        required property var modelData
                        width: tableCol.width
                        height: 26
                        Rectangle {
                            width: parent.width; height: 1
                            anchors.bottom: parent.bottom
                            color: theme.lineSoft
                        }
                        Text {
                            width: parent.width * 0.68
                            anchors.verticalCenter: parent.verticalCenter
                            text: rowItem.modelData.name
                            font.family: theme.fontFamily; font.pixelSize: theme.fontSmall
                            color: theme.text
                        }
                        Text {
                            x: parent.width * 0.68
                            width: parent.width * 0.32
                            anchors.verticalCenter: parent.verticalCenter
                            text: rowItem.modelData.action
                            font.family: theme.fontFamily; font.pixelSize: theme.fontSmall
                            color: rowItem.modelData.isDelete ? theme.danger : theme.muted
                        }
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
            UiBtn { text: qsTr("Next"); primary: true; onClicked: page.nextRequested() }
        }
    }
}
