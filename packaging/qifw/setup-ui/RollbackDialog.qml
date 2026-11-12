// RollbackDialog.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// "Roll back data" dialog (design: 回滚数据 / 回滚原程序和原配置), built on the same measured
// skeleton as the failure dialog: a 560px content card (rx16, 1px #DFDFDF edge) whose bottom hosts
// a separate 560x84 footer strip. The strip's buttons sit at window y=427 (92px 取消 + 124px 确定,
// 44px high, rx8). Inside the card: a 47px-row snapshot list with d19 radios, then the warning strip
// describing what the rollback clears.
Item {
    id: dlg
    UiTheme { id: theme }

    property bool open: false
    // [{ name, version, createdAt, bytes }] - newest first, straight from the engine.
    property var snapshots: []
    property string selectedName: ""
    property string errorText: ""

    signal cancelRequested()
    signal confirmRequested()

    visible: open
    z: 100

    function selected() {
        for (let i = 0; i < dlg.snapshots.length; ++i) {
            if (dlg.snapshots[i].name === dlg.selectedName)
                return dlg.snapshots[i]
        }
        return dlg.snapshots.length > 0 ? dlg.snapshots[0] : null
    }
    function fmtBytes(n) {
        const gb = (n || 0) / (1024 * 1024 * 1024)
        return gb >= 1 ? gb.toFixed(1) + " GB" : Math.max(1, Math.round((n || 0) / (1024 * 1024))) + " MB"
    }
    function fmtTime(iso) {
        // ISO 8601 -> "2026-11-11 21:30" (design shows date and time on two lines for the snapshot list).
        if (!iso || iso.length < 16) return iso || ""
        return iso.substring(0, 10) + " " + iso.substring(11, 16)
    }
    function warningText() {
        const s = dlg.selected()
        if (!s) return qsTr("No snapshot available.")
        return qsTr("Configuration will be rolled back to %1 (%2). Changes made after that point are removed; please proceed carefully.")
                  .arg(s.name).arg(dlg.fmtTime(s.createdAt))
    }

    // --- Scrim (#0E1314 @52%) ---
    Rectangle {
        anchors.fill: parent
        color: theme.scrim
    }

    Item {
        id: skeleton
        width: theme.dialogCardW
        height: theme.dialogCardH
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - theme.dialogBottomMargin - height

        Rectangle {
            id: card
            anchors.fill: parent
            radius: theme.radiusDialog
            color: theme.white
            border.width: 1
            border.color: theme.dialogEdge
            clip: true

            Column {
                x: 24
                width: parent.width - 48
                spacing: 0

                Item {
                    width: parent.width
                    height: theme.dialogHeaderH

                    Text {
                        anchors.left: parent.left
                        anchors.right: closeBtn.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Roll back data")
                        elide: Text.ElideRight
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontDialogTitle
                        font.weight: Font.DemiBold
                        color: theme.textStrong
                    }

                    Item {
                        id: closeBtn
                        width: 24
                        height: 24
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            anchors.centerIn: parent
                            width: 2
                            height: 14
                            radius: 1
                            rotation: 45
                            color: closeMa.containsMouse ? theme.danger : theme.dialogClose
                        }
                        Rectangle {
                            anchors.centerIn: parent
                            width: 2
                            height: 14
                            radius: 1
                            rotation: -45
                            color: closeMa.containsMouse ? theme.danger : theme.dialogClose
                        }
                        MouseArea {
                            id: closeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: dlg.cancelRequested()
                        }
                    }
                }

                // Snapshot list: one 47px row per snapshot, selected row marked with its radio.
                Rectangle {
                    width: parent.width
                    height: listColumn.height
                    radius: theme.radiusCard
                    color: theme.white
                    border.width: 1
                    border.color: theme.dialogEdge

                    Column {
                        id: listColumn
                        width: parent.width

                        Repeater {
                            model: dlg.snapshots
                            delegate: Item {
                                id: row
                                required property int index
                                required property var modelData
                                readonly property bool current: modelData.name === dlg.selectedName
                                readonly property bool last: row.index === dlg.snapshots.length - 1

                                width: listColumn.width
                                height: theme.dialogRowH

                                UiRadio {
                                    id: rowRadio
                                    x: 11
                                    anchors.verticalCenter: parent.verticalCenter
                                    compact: true
                                    checked: row.current
                                    onToggled: dlg.selectedName = row.modelData.name
                                }

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 39
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(0, parent.width - 39 - 200)
                                    text: row.modelData.name
                                    elide: Text.ElideRight
                                    font.family: theme.fontFamily
                                    font.pixelSize: theme.fontBody
                                    color: row.current ? theme.dialogInk : theme.textBody
                                }

                                // Right cell: version + size, then the creation time (design shows both columns).
                                Text {
                                    anchors.right: timeText.left
                                    anchors.rightMargin: 16
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 96
                                    horizontalAlignment: Text.AlignRight
                                    elide: Text.ElideRight
                                    text: (row.modelData.version && row.modelData.version.length > 0 ? row.modelData.version : "—")
                                          + " · " + dlg.fmtBytes(row.modelData.bytes)
                                    font.family: theme.fontFamily
                                    font.pixelSize: theme.fontSmall
                                    color: theme.muted
                                }
                                Text {
                                    id: timeText
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: dlg.fmtTime(row.modelData.createdAt)
                                    font.family: theme.fontFamily
                                    font.pixelSize: theme.fontBody
                                    color: row.current ? theme.brand : theme.textBody
                                }

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 41
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    visible: !row.last
                                    height: 1
                                    color: theme.divider
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: dlg.selectedName = row.modelData.name
                                }
                            }
                        }
                    }
                }

                Item { width: 1; height: 10 }

                // Warning strip: what a rollback clears (measured: brand wash, 1px brand border, 16px badge).
                Rectangle {
                    width: parent.width
                    height: warnRow.implicitHeight + 24
                    radius: theme.radiusCard
                    color: theme.cardTeal
                    border.width: 1
                    border.color: theme.brand

                    RowLayout {
                        id: warnRow
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 10

                        Rectangle {
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: 3
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
                            Layout.fillWidth: true
                            text: dlg.warningText()
                            wrapMode: Text.WordWrap
                            lineHeight: 1.0
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontBody
                            color: theme.text
                        }
                    }
                }

                Text {
                    width: parent.width
                    topPadding: 8
                    visible: dlg.errorText.length > 0
                    text: dlg.errorText
                    wrapMode: Text.WordWrap
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSmall
                    color: theme.danger
                }
            }
        }

        // Footer strip (560x84, bottom edge on window y=491, buttons 20px inside).
        Rectangle {
            x: 0
            y: skeleton.height - height
            width: skeleton.width
            height: theme.dialogFooterH
            radius: theme.radiusDialog
            color: theme.white

            UiBtn {
                x: (skeleton.width - 22) - theme.btnW - 10 - theme.btnHugW
                y: 20
                text: qsTr("Cancel")
                hug: true
                onClicked: dlg.cancelRequested()
            }
            UiBtn {
                x: (skeleton.width - 22) - theme.btnW
                y: 20
                text: qsTr("Confirm")
                primary: true
                enabledState: dlg.snapshots.length > 0
                onClicked: dlg.confirmRequested()
            }
        }
    }
}
