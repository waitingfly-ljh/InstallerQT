// MaintenancePage.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// Maintenance screens (design: 覆盖升级 / 降级安装 / 修复): current vs. installer version cards, the
// list of data that survives the operation, and - for a downgrade - the incompatibility warning that
// must be acknowledged before the primary button becomes available.
//
// Geometry from 覆盖升级 / 降级安装 (measured; content column starts at window y=36, page y = window y - 36):
//   title ink      41.5..64.2   -> page   5.5..28.2
//   lead ink       78.5..93.7   -> page  42.5..57.7
//   version cards  103..201     -> page  67..165   (outer 202x98 rx13.5 white + #F5F5F5 edge;
//                                     inner 170x80 rx14 #FBFBFB at +16/+9; card x = -16 and 256)
//   retain card    202.5..340.5 -> page 166.5..304.5 (441x138 rx13.5, #EDF6FF@32% + #9ACDFF)
//   warning card   347.5..479.5 -> page 311.5..443.5 (441x132 rx13.5, #FFF7E9 + #F0D5A3)
//   action row     476..520     -> page 440..484
// The downgrade variant is 574px tall in the design (buttons at 522), so the body scrolls: the whole
// column - buttons included - lives inside UiScrollArea.
Item {
    id: page
    UiTheme { id: theme }

    width: theme.contentW
    height: theme.contentH

    property string mode: "repair"           // repair | upgrade | downgrade
    property string currentVersion: ""
    property string targetVersion: ""
    property bool riskAcknowledged: false
    signal proceedRequested(mode: string)
    signal cancelRequested()
    signal restoreRequested()
    signal riskToggled(bool checked)

    readonly property bool downgrade: mode === "downgrade"
    readonly property string title: mode === "repair" ? qsTr("Repair OrbbecSlicer")
                                  : mode === "upgrade" ? qsTr("Upgrade OrbbecSlicer")
                                  : qsTr("Downgrade OrbbecSlicer")
    // Leads stay short enough to render on one line inside the 442px content column (the design
    // shows a single lead line on all three maintenance screens).
    readonly property string lead: mode === "repair"
        ? qsTr("Same version installed; repair keeps all your data.")
        : mode === "upgrade"
        ? qsTr("Overwrites program files; your data is kept.")
        : qsTr("Older installer: acknowledge the risk to continue.")
    readonly property string primaryText: mode === "repair" ? qsTr("Start repair")
                                        : mode === "upgrade" ? qsTr("Start upgrade")
                                        : qsTr("Confirm and downgrade")
    readonly property var retained: [
        qsTr("Custom presets"), qsTr("Software preferences"), qsTr("Account session"),
        qsTr("Calibration results"), qsTr("Printer info"), qsTr("LAN access code")
    ]

    UiScrollArea {
        anchors.fill: parent

        Item {
            id: body
            width: page.width
            height: page.downgrade ? 538 : 484

            Text {
                x: 0
                y: 0
                width: parent.width
                text: page.title
                wrapMode: Text.WordWrap
                font.family: theme.fontFamily
                font.pixelSize: theme.fontTitle
                font.weight: theme.fontTitleWeight
                color: theme.brand
            }

            Text {
                x: 0
                y: 39
                width: parent.width
                text: page.lead
                wrapMode: Text.WordWrap
                font.family: theme.fontFamily
                font.pixelSize: theme.fontLead
                color: theme.textBody
            }

            // --- Version comparison: outer 202x98 white card with a #F5F5F5 edge, inner 170x80
            // #FBFBFB block, the installer side additionally tinted brand@5% with a brand edge.
            Item {
                id: versions
                x: 0
                y: page.downgrade ? 63 : 67
                width: parent.width
                height: 98

                // Left (installed) card: measured at window x=482, i.e. 16px left of the column.
                Rectangle {
                    x: -16
                    width: 202
                    height: 98
                    radius: theme.radiusCard
                    color: theme.white
                    border.width: 1
                    border.color: theme.fieldOutline

                    Rectangle {
                        x: 16
                        y: 9
                        width: 170
                        height: 80
                        radius: theme.radiusVersionCard
                        color: theme.cardPlain
                    }
                    Text {
                        x: 30.5
                        y: 13
                        width: 150
                        height: 17
                        text: qsTr("Current version")
                        elide: Text.ElideRight
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.muted
                    }
                    Text {
                        x: 30.5
                        y: 40
                        width: 150
                        height: 22
                        text: page.currentVersion.length > 0 ? page.currentVersion : qsTr("Unknown")
                        elide: Text.ElideRight
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontValue
                        color: theme.text
                    }
                }

                // Arrow between the cards (measured bbox 690..749, vertically centred on the cards).
                Text {
                    x: 192
                    y: 39
                    width: 59
                    height: 20
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: "→"
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontCardTitle
                    color: theme.brand
                }

                // Right (installer) card: measured at window x=754.
                Rectangle {
                    x: 256
                    width: 202
                    height: 98
                    radius: theme.radiusCard
                    color: theme.white
                    border.width: 1
                    border.color: theme.fieldOutline

                    Rectangle {
                        x: 16
                        y: 9
                        width: 170
                        height: 80
                        radius: theme.radiusVersionCard
                        color: theme.cardPlain
                    }
                    Rectangle {
                        x: 16.5
                        y: 9.5
                        width: 169
                        height: 79
                        radius: theme.radiusCard
                        color: theme.alpha(theme.brand, 0.05)
                        border.width: 1
                        border.color: theme.brand
                    }
                    Text {
                        x: 30.5
                        y: 13
                        width: 150
                        height: 17
                        text: qsTr("Installer version")
                        elide: Text.ElideRight
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.muted
                    }
                    Text {
                        x: 30.5
                        y: 40
                        width: 150
                        height: 22
                        text: page.targetVersion
                        elide: Text.ElideRight
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontValue
                        color: theme.brand
                    }
                }
            }

            // --- Data that survives the operation (441x138 card, ✓ disc d16, 2 columns x 3 rows,
            // 238px column pitch, 28px row pitch).
            Rectangle {
                x: 0
                y: page.downgrade ? 162.5 : 166.5
                width: parent.width
                height: 138
                radius: theme.radiusCard
                color: theme.cardBlue
                border.width: 1
                border.color: theme.cardBlueLine

                // 16px brand disc with a white tick (measured at window x=512).
                Rectangle {
                    x: 13.5
                    y: 17.5
                    width: 16
                    height: 16
                    radius: 8
                    color: theme.brand
                    Text {
                        anchors.centerIn: parent
                        text: "✓"
                        color: theme.white
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSmall
                        font.weight: Font.Bold
                    }
                }
                Text {
                    x: 41
                    y: 15
                    width: parent.width - 41 - 16
                    height: 20
                    verticalAlignment: Text.AlignVCenter
                    text: qsTr("The following data will be kept")
                    elide: Text.ElideRight
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBodyLg
                    font.weight: Font.DemiBold
                    color: theme.text
                }

                Repeater {
                    model: page.retained
                    delegate: Item {
                        id: retainRow
                        required property int index
                        required property string modelData
                        x: (retainRow.index % 2) * 238 + 13.5
                        y: 45 + Math.floor(retainRow.index / 2) * 28
                        width: 220
                        height: 16

                        Text {
                            x: 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: "✓"
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontBody
                            font.weight: Font.Bold
                            color: theme.brand
                        }
                        Text {
                            x: 25
                            anchors.verticalCenter: parent.verticalCenter
                            text: retainRow.modelData
                            elide: Text.ElideRight
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontBody
                            color: theme.textBody
                        }
                    }
                }
            }

            // --- Downgrade warning (441x132). The acknowledgement checkbox lives inside the card
            // (design 降级安装-1: 16px box at window y=445).
            Rectangle {
                x: 0
                y: 311.5
                width: parent.width
                height: 132
                visible: page.downgrade
                radius: theme.radiusCard
                color: theme.cardWarn
                border.width: 1
                border.color: theme.cardWarnLine

                Rectangle {
                    x: 13.5
                    y: 17.5
                    width: 16
                    height: 16
                    radius: 8
                    color: theme.brand
                    Text {
                        anchors.centerIn: parent
                        text: "!"
                        color: theme.white
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontCheck
                        font.weight: Font.Bold
                    }
                }
                Text {
                    x: 41
                    y: 15
                    width: parent.width - 41 - 16
                    height: 20
                    verticalAlignment: Text.AlignVCenter
                    text: qsTr("Downgrading may cause configuration incompatibility")
                    elide: Text.ElideRight
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBodyLg
                    font.weight: Font.DemiBold
                    color: theme.text
                }
                Text {
                    x: 39.5
                    y: 44
                    width: parent.width - 39.5 - 16
                    text: qsTr("A recoverable snapshot is created before installation. Configuration the old version cannot read is quarantined instead of being overwritten.")
                    wrapMode: Text.WordWrap
                    lineHeight: 1.46
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    color: theme.textBody
                }
                UiCheck {
                    x: 42.5
                    y: 93.5
                    strong: true
                    width: parent.width - 42.5 - 16
                    text: qsTr("I understand the risk and want to install the older version")
                    checked: page.riskAcknowledged
                    onToggled: page.riskToggled(!page.riskAcknowledged)
                }
            }

            // --- Action row: recovery entry on the left (only when snapshots exist), 取消 + primary
            // on the right (design: x=678/816 at y=476).
            Row {
                id: actionRow
                x: parent.width - width
                y: page.downgrade ? 486 : 440
                spacing: theme.btnGap

                Item {
                    visible: Host.engine.snapshots.length > 0
                    width: visible ? restoreRow.implicitWidth : 0
                    height: theme.btnH
                    Row {
                        id: restoreRow
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Restore a snapshot")
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontBody
                            font.underline: restoreMa.containsMouse
                            color: theme.brand
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "(" + Host.engine.snapshots.length + ")"
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontBody
                            color: theme.muted
                        }
                    }
                    MouseArea {
                        id: restoreMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.restoreRequested()
                    }
                }
                UiBtn { text: qsTr("Cancel"); onClicked: page.cancelRequested() }
                UiBtn {
                    text: page.primaryText
                    primary: true
                    chevron: "right"
                    enabledState: !page.downgrade || page.riskAcknowledged
                    onClicked: page.proceedRequested(page.mode)
                }
            }
        }
    }
}
