// ErrorDialog.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// Modal failure dialog, in two measured skeletons (the design ships two different frames for the
// same job, and they are not the same component):
//
//   Skeleton A - with a step list (design: 迁移失败). 560px content card (rx16, 1px #DFDFDF edge)
//   whose bottom third is a separate 560x84 footer strip. The strip's buttons sit at window y=427
//   (92px 取消 + 124px primary, 44px high, rx8), i.e. 20px inside the strip.
//
//   Skeleton B - error code + retry, no step list (design: 显示错误代码与重试). 730x273 card (rx16)
//   with a 53px #FF5C45 header band, a 15px body line, and two 124x44 buttons at the card bottom
//   (取消 / 重试, 重试 filled #FF5038).
//
// The step list is data, not a hardcoded animation: SetupController derives it from the phase the
// engine had reached, so it never claims progress the installer did not make. When the controller
// has no phases (no steps) the dialog falls back to skeleton B.
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

    readonly property bool withSteps: dlg.steps.length > 0

    function statusLabel(state) {
        if (state === "done") return qsTr("OK")
        if (state === "failed") return qsTr("Failed")
        return qsTr("Pending")
    }
    function statusInk(state) {
        if (state === "done") return theme.statusOk
        if (state === "failed") return theme.statusFail
        return theme.muted
    }

    // --- Scrim (#0E1314 @52%) ---
    Rectangle {
        anchors.fill: parent
        color: theme.scrim
    }

    // =====================================================================================
    // Skeleton A: step list + header + hint, with the measured 84px footer strip
    // =====================================================================================
    Item {
        id: skeletonA
        visible: dlg.withSteps
        width: theme.dialogCardW
        height: theme.dialogCardH
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - theme.dialogBottomMargin - height

        Rectangle {
            id: cardA
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

                // Title + close glyph (design title em≈15, red for failures, #262E30 for rollback).
                Item {
                    width: parent.width
                    height: theme.dialogHeaderH

                    Text {
                        anchors.left: parent.left
                        anchors.right: closeA.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: dlg.title
                        elide: Text.ElideRight
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontDialogTitle
                        font.weight: Font.DemiBold
                        color: theme.danger
                    }

                    Item {
                        id: closeA
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
                            color: closeAMa.containsMouse ? theme.danger : theme.dialogClose
                        }
                        Rectangle {
                            anchors.centerIn: parent
                            width: 2
                            height: 14
                            radius: 1
                            rotation: -45
                            color: closeAMa.containsMouse ? theme.danger : theme.dialogClose
                        }
                        MouseArea {
                            id: closeAMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: dlg.cancelRequested()
                        }
                    }
                }

                // Step card: white box, 1px edge, 47px rows with 1px rules.
                Rectangle {
                    width: parent.width
                    height: stepColumn.height
                    radius: theme.radiusCard
                    color: theme.white
                    border.width: 1
                    border.color: theme.dialogEdge

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
                                // Measured inside the step card: icon 11..30, label at 39, rule from 41,
                                // status right-aligned inside a 98px cell.
                                readonly property int iconCenter: 11 + 9.5

                                width: stepColumn.width
                                height: theme.dialogRowH

                                // Connector: brand fading into the design's bright teal, drawn above
                                // this row (except the first) and below it (except the last).
                                Rectangle {
                                    x: stepRow.iconCenter - 2
                                    y: 0
                                    visible: stepRow.index > 0
                                    width: 4
                                    height: stepRow.height / 2 - 9.5
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: theme.stepLineEnd }
                                        GradientStop { position: 1.0; color: theme.brand }
                                    }
                                }
                                Rectangle {
                                    x: stepRow.iconCenter - 2
                                    y: stepRow.height / 2 + 9.5
                                    visible: !stepRow.last
                                    width: 4
                                    height: stepRow.height / 2 - 9.5
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: theme.brand }
                                        GradientStop { position: 1.0; color: theme.stepLineEnd }
                                    }
                                }

                                // State icon: 19px - done (brand ✓), failed (red ×), pending (grey ring
                                // with a grey dot, as drawn on the design's running row).
                                Rectangle {
                                    x: 11
                                    width: 19
                                    height: 19
                                    radius: 9.5
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: stepRow.state === "done" ? theme.brand
                                         : stepRow.state === "failed" ? theme.danger
                                         : theme.white
                                    border.width: stepRow.state === "pending" ? 2 : 0
                                    border.color: theme.hairline
                                    Text {
                                        anchors.centerIn: parent
                                        visible: stepRow.state !== "pending"
                                        text: stepRow.state === "done" ? "✓" : "×"
                                        color: theme.white
                                        font.family: theme.fontFamily
                                        font.pixelSize: theme.fontCheck
                                        font.weight: Font.Bold
                                    }
                                    Rectangle {
                                        anchors.centerIn: parent
                                        visible: stepRow.state === "pending"
                                        width: 9
                                        height: 9
                                        radius: 4.5
                                        color: theme.mutedSoft
                                    }
                                }

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 39
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(0, parent.width - 39 - 100)
                                    text: stepRow.modelData.label
                                    elide: Text.ElideRight
                                    font.family: theme.fontFamily
                                    font.pixelSize: theme.fontBody
                                    color: stepRow.state === "pending" ? theme.textBody : theme.dialogInk
                                }

                                // Status column: centred 98px cell so 2- and 3-character labels share
                                // one axis (measured: 完成 675.5..701, 待执行 670.5..706.5).
                                Text {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
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
                                    anchors.leftMargin: 41
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    visible: !stepRow.last
                                    height: 1
                                    color: theme.divider
                                }
                            }
                        }
                    }
                }

                Item { width: 1; height: 10; visible: dlg.message.length > 0 }

                // Hint strip: brand wash with a 1px brand border and the design's 16px "!" badge.
                Rectangle {
                    visible: dlg.message.length > 0
                    width: parent.width
                    height: hintRow.implicitHeight + 24
                    radius: theme.radiusCard
                    color: theme.cardTeal
                    border.width: 1
                    border.color: theme.brand

                    RowLayout {
                        id: hintRow
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
                            text: dlg.message
                            wrapMode: Text.WordWrap
                            lineHeight: 1.0
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontBody
                            color: theme.text
                        }
                    }
                }

                Text {
                    visible: dlg.code.length > 0
                    width: parent.width
                    topPadding: 8
                    text: qsTr("Error code %1").arg(dlg.code)
                    elide: Text.ElideRight
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontFoot
                    color: theme.muted
                }
            }
        }

        // Footer strip: 560x84, its bottom edge on window y=491; buttons 20px inside it.
        Rectangle {
            id: footerA
            x: 0
            y: skeletonA.height - height
            width: skeletonA.width
            height: theme.dialogFooterH
            radius: theme.radiusDialog
            color: theme.white

            UiBtn {
                x: (skeletonA.width - 22) - theme.btnW - 10 - theme.btnHugW
                y: 20
                text: qsTr("Cancel")
                hug: true
                onClicked: dlg.cancelRequested()
            }
            UiBtn {
                x: (skeletonA.width - 22) - theme.btnW
                y: 20
                text: qsTr("Retry")
                primary: true
                onClicked: dlg.retryRequested()
            }
        }
    }

    // =====================================================================================
    // Skeleton B: error code + retry (no step list)
    // =====================================================================================
    Rectangle {
        id: cardB
        visible: !dlg.withSteps
        width: theme.dialogErrorW
        height: theme.dialogErrorH
        anchors.centerIn: parent
        radius: theme.radiusDialog
        color: theme.white
        border.width: 1
        border.color: theme.dialogEdge
        clip: true

        // 53px red header band (square corners; the card's clip rounds them).
        Rectangle {
            width: parent.width
            height: theme.dialogErrorBand
            color: theme.dangerHeader
        }

        Text {
            x: 22
            y: 0
            height: theme.dialogErrorBand
            width: parent.width - 22 - 60
            verticalAlignment: Text.AlignVCenter
            text: dlg.title
            elide: Text.ElideRight
            font.family: theme.fontFamily
            font.pixelSize: theme.fontErrorBand
            font.weight: Font.DemiBold
            color: theme.dangerHeaderInk
        }

        Item {
            id: closeB
            width: 24
            height: 24
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.top: parent.top
            anchors.topMargin: (theme.dialogErrorBand - height) / 2
            Rectangle {
                anchors.centerIn: parent
                width: 2
                height: 14
                radius: 1
                rotation: 45
                color: closeBMa.containsMouse ? theme.white : theme.dangerHeaderInk
            }
            Rectangle {
                anchors.centerIn: parent
                width: 2
                height: 14
                radius: 1
                rotation: -45
                color: closeBMa.containsMouse ? theme.white : theme.dangerHeaderInk
            }
            MouseArea {
                id: closeBMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: dlg.cancelRequested()
            }
        }

        // Body: measured ink 288..304 (window) => 154..170 inside the card, i.e. clear of the band.
        Text {
            id: bodyB
            x: 94
            y: 147
            width: parent.width - 94 - 24
            text: dlg.message
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontBodyLg
            color: theme.text
        }

        Text {
            visible: dlg.code.length > 0
            x: 94
            y: bodyB.y + bodyB.implicitHeight + 6
            width: parent.width - 94 - 24
            text: qsTr("Error code %1").arg(dlg.code)
            elide: Text.ElideRight
            font.family: theme.fontFamily
            font.pixelSize: theme.fontFoot
            color: theme.muted
        }

        // Measured: 取消 x=446, 重试 x=584, both 124x44 at y=207 inside the card.
        UiBtn {
            x: 446
            y: 207
            text: qsTr("Cancel")
            onClicked: dlg.cancelRequested()
        }
        UiBtn {
            x: 584
            y: 207
            text: qsTr("Retry")
            danger: true
            onClicked: dlg.retryRequested()
        }
    }
}
