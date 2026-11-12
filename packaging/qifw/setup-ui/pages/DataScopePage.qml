// DataScopePage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Uninstall 1/3: choose the data scope. Defaults to "Keep personal data"; the category table reflects
// the selection.
//
// Geometry from the 卸载 frame (all measured; the content column starts at window y=36, so page y =
// window y - 36):
//   title ink 42..63                     -> page   6..27
//   lead ink 79..92 (14px)               -> page  43..56
//   option 1 card 120..199 (80px)        -> page  84..163  (#fbfbfb, #efefef border)
//   option 2 card 216..295 (80px)        -> page 180..259  (#eef5f5, brand border = selected)
//   table header 312..351 (40px)         -> page 276..315  (#f9fcff, #d7eafe border)
//   data rows 352..403, 405..454, ...    -> page 316.., 52px each (2px separator)
// The table is taller than the viewport (the frame shows the 4th row cut off at the bottom edge and a
// page scroll bar at x=948..951), so the whole page body - including the action row - scrolls.
Item {
    id: page

    UiTheme { id: theme }
    width: theme.contentW
    height: theme.contentH
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

    readonly property var scopeOptions: [
        { "removeAll": false,
          "title": qsTr("Keep personal data"),
          "tag": qsTr("Recommended"),
          "detail": qsTr("Presets, calibration results, preferences and device info are kept; caches and login credentials are cleared.") },
        { "removeAll": true,
          "title": qsTr("Delete all application data on this machine"),
          "tag": "",
          "detail": qsTr("Presets, calibration results, preferences and device info are deleted as well.") }
    ]

    UiScrollArea {
        anchors.fill: parent

        Column {
            width: parent.width
            spacing: 0

            // Title row: 24px high so the ink lands on its top edge (design ink 42..63 window).
            Item {
                width: parent.width
                height: 24
                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    text: qsTr("What should happen to personal data?")
                    elide: Text.ElideRight
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontTitle
                    font.weight: theme.fontTitleWeight
                    color: theme.brand
                }
            }
            Item { width: 1; height: 16 }
            Item {
                width: parent.width
                height: 16
                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    text: qsTr("Choose the data scope for this machine.")
                    elide: Text.ElideRight
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    color: theme.textBody
                }
            }
            Item { width: 1; height: 28 }

            // Two 80px option cards (radio d19 at 14.5px inset, 16px title + optional "推荐" pill at
            // 45px, 13px detail line below). The measured card is 442x80 rx13.5.
            Repeater {
                model: page.scopeOptions
                delegate: Item {
                    id: optionSlot
                    required property var modelData
                    required property int index
                    width: page.width
                    height: theme.optionCardH + (index === 0 ? 16 : 0)
                    readonly property bool selected: page.removeAllData === modelData.removeAll

                    Rectangle {
                        width: parent.width
                        height: theme.optionCardH
                        radius: theme.radiusCard
                        color: optionSlot.selected ? theme.cardSelected : theme.cardPlain
                        border.width: 1
                        border.color: optionSlot.selected ? theme.brand : theme.cardPlainLine
                    }

                    // Radio: d19 ring; the selected one also carries a d14 brand dot.
                    UiRadio {
                        x: 14.5
                        anchors.verticalCenter: parent.top
                        anchors.verticalCenterOffset: theme.optionCardH / 2
                        compact: true
                        checked: optionSlot.selected
                        onToggled: {
                            page.removeAllData = optionSlot.modelData.removeAll
                            page.modeSelected(optionSlot.modelData.removeAll)
                        }
                    }

                    Row {
                        x: theme.optionCardInkX
                        y: 17
                        height: 20
                        spacing: 10
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: optionSlot.modelData.title
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontCardInk
                            font.weight: Font.DemiBold
                            color: optionSlot.selected ? theme.brand : theme.textBody
                        }
                        // "推荐" pill (measured: 42x20 rx6, brand fill, 12px white label).
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: optionSlot.modelData.tag.length > 0
                            width: Math.max(42, tagText.implicitWidth + 8)
                            height: theme.tagH
                            radius: theme.radiusTag
                            color: theme.brand
                            Text {
                                id: tagText
                                anchors.centerIn: parent
                                text: optionSlot.modelData.tag
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontSmall
                                color: theme.white
                            }
                        }
                    }

                    Item {
                        x: theme.optionCardInkX
                        y: 50
                        width: parent.width - theme.optionCardInkX - 14
                        height: 16
                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: optionSlot.modelData.detail
                            elide: Text.ElideRight
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontBody
                            color: theme.textFaint
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            page.removeAllData = optionSlot.modelData.removeAll
                            page.modeSelected(optionSlot.modelData.removeAll)
                        }
                    }
                }
            }

            Item { width: 1; height: 16 }

            // Category table: 40px header band, then 52px rows with a 1px #A6A6A6 @23% rule.
            Rectangle {
                width: parent.width
                height: theme.tableHeadH
                radius: theme.radiusCard
                color: theme.tableHeadBg
                border.width: 1
                border.color: theme.tableHeadLine

                Text {
                    x: 5
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Data")
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    color: theme.tableHeadInk
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.removeAllData ? qsTr("Delete all") : qsTr("Default uninstall")
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    color: theme.tableHeadInk
                }
            }

            Repeater {
                model: page.dataRows
                delegate: Item {
                    id: rowItem
                    required property var modelData
                    width: page.width
                    height: theme.tableRowH

                    Text {
                        x: 2
                        anchors.verticalCenter: parent.verticalCenter
                        text: rowItem.modelData.name
                        elide: Text.ElideRight
                        width: parent.width - 100
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.rowInk
                    }

                    // Action pill (measured: 68x32 rx16; orange #FF8812 on 10%, grey #ECECEC).
                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: theme.chipW
                        height: theme.chipH
                        radius: theme.chipRadius
                        color: rowItem.modelData.isDelete ? theme.chipWarnBg : theme.chipNeutralBg

                        Text {
                            anchors.fill: parent
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: rowItem.modelData.action
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontBody
                            color: rowItem.modelData.isDelete ? theme.chipWarnInk : theme.chipNeutralInk
                        }
                    }

                    // 1px #A6A6A6 @23% separator (measured on the 卸载 table).
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 1
                        color: theme.divider
                    }
                }
            }

            Item { width: 1; height: 20 }

            // Action row scrolls with the body: the frame has no footer - the table runs past the
            // bottom edge instead.
            RowLayout {
                width: parent.width
                height: 44
                spacing: theme.btnGap
                UiBtn { text: qsTr("Cancel"); onClicked: page.cancelRequested() }
                Item { Layout.fillWidth: true }
                UiBtn { text: qsTr("Next"); primary: true; chevron: "right"; onClicked: page.nextRequested() }
            }
            Item { width: 1; height: 20 }
        }
    }
}
