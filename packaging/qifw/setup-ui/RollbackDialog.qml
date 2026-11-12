// RollbackDialog.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// "Roll back data" dialog (design: 回滚数据 frame): a modal list of the pre-install snapshots with the
// selected one marked, a warning strip describing what the rollback clears, and 取消 / 确定.
// It shares the measured dialog chrome with ErrorDialog (558px card, 16px radius, 79px header,
// 47px rows, 21px side padding) so both modal surfaces look like the same component.
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

    // --- Scrim ---
    Rectangle {
        anchors.fill: parent
        color: theme.scrim
    }

    // --- Card ---
    Rectangle {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: theme.dialogW
        implicitHeight: layout.implicitHeight + theme.dialogPadBottom
        radius: theme.radiusDialog
        border.width: 1
        border.color: "#f0f0f0"
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#f1f9f9" }
            GradientStop { position: 0.18; color: "#fbfbfb" }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: -5
            radius: theme.radiusDialog + 5
            color: theme.alpha(theme.shadow, 0.10)
            z: -2
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: -2
            radius: theme.radiusDialog + 2
            color: theme.alpha(theme.shadow, 0.06)
            z: -1
        }

        ColumnLayout {
            id: layout
            anchors.fill: parent
            anchors.leftMargin: theme.dialogPad
            anchors.rightMargin: theme.dialogPad
            anchors.topMargin: 0
            anchors.bottomMargin: theme.dialogPadBottom
            spacing: 0

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: theme.dialogHeaderH

                Text {
                    anchors.left: parent.left
                    anchors.right: closeBtn.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Roll back data")
                    elide: Text.ElideRight
                    font.family: theme.fontFamily
                    font.pixelSize: 16
                    font.weight: Font.Bold
                    color: theme.text
                }

                Item {
                    id: closeBtn
                    width: 24
                    height: 24
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        font.family: theme.fontFamily
                        font.pixelSize: 20
                        color: closeMa.containsMouse ? theme.text : theme.mutedSoft
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

            // Snapshot list: one 47px row per snapshot, selected row marked with a brand dot.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: listColumn.implicitHeight
                radius: theme.radiusCard
                color: theme.white
                border.width: 1
                border.color: "#f0f0f0"

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

                            Rectangle {
                                x: 12
                                width: 18
                                height: 18
                                radius: 9
                                anchors.verticalCenter: parent.verticalCenter
                                color: row.current ? theme.brand : theme.white
                                border.width: row.current ? 0 : 1
                                border.color: theme.mutedSoft
                                Text {
                                    anchors.centerIn: parent
                                    visible: row.current
                                    text: "✓"
                                    color: theme.white
                                    font.family: theme.fontFamily
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                }
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 41
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.max(0, parent.width - 41 - 200)
                                text: row.modelData.name
                                elide: Text.ElideRight
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                color: theme.text
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
                                anchors.verticalCenter: parent.verticalCenter
                                text: dlg.fmtTime(row.modelData.createdAt)
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                color: row.current ? theme.brand : theme.textBody
                            }

                            Rectangle {
                                anchors.left: parent.left
                                anchors.leftMargin: 43
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                visible: !row.last
                                height: 1
                                color: theme.lineSoft
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

            Item { Layout.preferredHeight: 10 }

            // Warning strip: what a rollback clears (same strip grammar as the failure dialog hint).
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: warnRow.implicitHeight + 24
                radius: theme.radius
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
                            font.pixelSize: 12
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
                Layout.fillWidth: true
                Layout.topMargin: 8
                visible: dlg.errorText.length > 0
                text: dlg.errorText
                wrapMode: Text.WordWrap
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSmall
                color: theme.danger
            }

            Item { Layout.preferredHeight: 30 }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Item { Layout.fillWidth: true }
                UiBtn { text: qsTr("Cancel"); hug: true; onClicked: dlg.cancelRequested() }
                UiBtn {
                    text: qsTr("Confirm")
                    primary: true
                    enabledState: dlg.snapshots.length > 0
                    onClicked: dlg.confirmRequested()
                }
            }
        }
    }
}
