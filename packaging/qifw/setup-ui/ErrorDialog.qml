// ErrorDialog.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// Modal failure dialog in the 11-11 design language (from the "配置迁移失败" frame), measured at
// 550x427: 16px side padding, a 79px header whose 16px red title is vertically centred, a white
// step card (47px rows, 1px dividers, 18px state dots joined by a connector), a #f2faf9 hint strip
// with a 1px brand border, then 取消 (92px, hug) / 重试 (124px) at the bottom right.
// The step list is data, not a hardcoded animation: SetupController derives it from the phase the
// engine had reached, so it never claims progress the installer did not make.
Item {
    id: dlg
    UiTheme { id: theme }

    property bool open: false
    // [{ "label": "...", "state": "done" | "failed" | "pending" }]
    property var steps: []
    property string title: qsTr("Installation failed")
    property string message: ""
    property string code: ""

    signal retryRequested()
    signal cancelRequested()

    visible: open
    z: 100

    function statusLabel(state) {
        if (state === "done") return qsTr("OK")
        if (state === "failed") return qsTr("Failed")
        return qsTr("Pending")
    }
    function statusInk(state) {
        if (state === "done") return theme.success
        if (state === "failed") return theme.danger
        return theme.muted
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
        // Design: the card fades from a very light teal at the top edge into near-white.
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#f1f9f9" }
            GradientStop { position: 0.18; color: "#fbfbfb" }
        }

        // Soft shadow: a couple of translucent rounded layers instead of an effect shader, so the
        // dialog does not depend on QtQuick.Effects being deployed.
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

            // Title row: the design centres a 16px red title in a 79px header band.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: theme.dialogHeaderH

                Text {
                    anchors.left: parent.left
                    anchors.right: closeBtn.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: dlg.title
                    elide: Text.ElideRight
                    font.family: theme.fontFamily
                    font.pixelSize: 16
                    font.weight: Font.Bold
                    color: theme.danger
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
                        color: closeMa.containsMouse ? theme.danger : theme.mutedSoft
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

            // Step card: white box with rounder corners on top of the tinted dialog background.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: stepColumn.implicitHeight
                radius: theme.radiusCard
                color: theme.white
                border.width: 1
                border.color: "#f0f0f0"

                Column {
                    id: stepColumn
                    width: parent.width

                    Repeater {
                        model: dlg.steps
                        delegate: Item {
                            id: stepRow
                            required property int index
                            required property var modelData
                            readonly property string state: modelData.state || "pending"
                            readonly property bool last: stepRow.index === dlg.steps.length - 1
                            // Measured inside the step card: icon 12..30, label at 41.5,
                            // divider from 43 to the card's right edge, status centred at 468.
                            readonly property int iconCenter: 12 + 9

                            width: stepColumn.width
                            height: theme.dialogRowH

                            // Connector: above this row (except the first) and below it (except the last),
                            // so the dots read as one vertical timeline like the design.
                            Rectangle {
                                x: stepRow.iconCenter - 1
                                y: 0
                                visible: stepRow.index > 0
                                width: 2
                                height: stepRow.height / 2 - 9
                                color: theme.brandLine
                            }
                            Rectangle {
                                x: stepRow.iconCenter - 1
                                y: stepRow.height / 2 + 9
                                visible: !stepRow.last
                                width: 2
                                height: stepRow.height / 2 - 9
                                color: theme.brandLine
                            }

                            // State icon: filled brand circle (done), filled red circle (failed),
                            // empty grey ring (pending).
                            Rectangle {
                                x: 12
                                width: 18
                                height: 18
                                radius: 9
                                anchors.verticalCenter: parent.verticalCenter
                                color: stepRow.state === "done" ? theme.brand
                                     : stepRow.state === "failed" ? theme.danger
                                     : theme.white
                                border.width: stepRow.state === "pending" ? 1 : 0
                                border.color: theme.mutedSoft
                                Text {
                                    anchors.centerIn: parent
                                    visible: stepRow.state !== "pending"
                                    text: stepRow.state === "done" ? "✓" : "×"
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
                                width: Math.max(0, parent.width - 41 - 100)
                                text: stepRow.modelData.label
                                elide: Text.ElideRight
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                color: stepRow.state === "pending" ? theme.muted : theme.text
                            }

                            // Status column: the design centres 2- and 3-character labels on the same
                            // axis (measured: "完成" 675.5..701 and "待执行" 670.5..706.5), so a centred
                            // 98px cell reproduces it for every label length.
                            Text {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: 98
                                horizontalAlignment: Text.AlignHCenter
                                text: dlg.statusLabel(stepRow.state)
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                color: dlg.statusInk(stepRow.state)
                            }

                            Rectangle {
                                anchors.left: parent.left
                                anchors.leftMargin: 43
                                anchors.right: parent.right
                                anchors.rightMargin: 0
                                anchors.bottom: parent.bottom
                                visible: !stepRow.last
                                height: 1
                                color: theme.lineSoft
                            }
                        }
                    }
                }
            }

            Item {
                Layout.preferredHeight: 10
                visible: dlg.message.length > 0
            }

            // Hint strip: #f2faf9 fill with a 1px brand border + "!" badge (measured on the design).
            Rectangle {
                visible: dlg.message.length > 0
                Layout.fillWidth: true
                implicitHeight: hintRow.implicitHeight + 24
                radius: theme.radius
                color: theme.cardTeal
                border.width: 1
                border.color: theme.brand

                RowLayout {
                    id: hintRow
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 10

                    // Design: 16px badge inset 11px from the strip, aligned with the first text line.
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
                        text: dlg.message
                        wrapMode: Text.WordWrap
                        // Natural line spacing: the design's hint lines sit 20.5px apart at 14px
                        // (Qt's proportional lineHeight multiplies font line spacing, not pixelSize,
                        // so a 1.45 multiplier would stretch the strip to 80px instead of 62px).
                        lineHeight: 1.0
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.text
                    }
                }
            }

            Item { Layout.preferredHeight: 30 }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    visible: dlg.code.length > 0
                    Layout.fillWidth: true
                    text: qsTr("Error code %1").arg(dlg.code)
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontFoot
                    color: theme.muted
                }
                Item { Layout.fillWidth: true }
                UiBtn { text: qsTr("Cancel"); hug: true; onClicked: dlg.cancelRequested() }
                UiBtn { text: qsTr("Retry"); primary: true; onClicked: dlg.retryRequested() }
            }
        }
    }
}
