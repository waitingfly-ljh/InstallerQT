// ProgressPage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Progress page: task name, percentage, progress bar, detail line, cancel.
// Progress comes from Host.engine's real output (phase + events); no fixed animation is played.
Item {
    id: page
    UiTheme { id: theme }

    width: theme.contentW
    height: theme.contentH

    property string heading: qsTr("Installing OrbbecSlicer")
    property string lead: qsTr("Keep this window open. The installation does not upload local projects or user presets.")
    property string phase: Host.engine.phase
    property int progress: Host.engine.progress
    property string detail: Host.engine.detail
    property bool canCancel: true
    // Final stage: the engine has finished, progress is pinned at 100%, and Cancel is disabled.
    property bool complete: false
    signal cancelRequested()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: page.heading
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.Bold
            color: theme.brand
        }
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.fillWidth: true
            text: page.lead
            wrapMode: Text.WordWrap
            lineHeight: 1.5
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.textBody
        }

        // Progress block: task name + percentage, bar, detail line. Vertically placed below the lead
        // (the action row is pushed to the bottom by the fillHeight spacer).
        Item {
            id: visual
            Layout.fillWidth: true
            Layout.topMargin: 132
            Layout.preferredHeight: visualCol.implicitHeight
            Layout.alignment: Qt.AlignHCenter

            Column {
                id: visualCol
                width: visual.width
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 9

                Item {
                    width: parent.width
                    height: percentText.height > phaseText.height ? percentText.height : phaseText.height

                    Text {
                        id: percentText
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: (page.complete ? 100 : page.progress) + "%"
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.muted
                    }
                    Text {
                        id: phaseText
                        anchors.left: parent.left
                        anchors.right: percentText.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: page.phase
                        elide: Text.ElideRight
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        font.bold: true
                        color: theme.text
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 9
                    radius: 20
                    clip: true
                    color: theme.track

                    Rectangle {
                        height: parent.height
                        radius: 20
                        width: parent.width * Math.max(0, Math.min(1, (page.complete ? 100 : page.progress) / 100))
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: theme.brand }
                            GradientStop { position: 1.0; color: theme.trackFillEnd }
                        }
                        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    }
                }

                Text {
                    width: parent.width
                    topPadding: 2
                    horizontalAlignment: Text.AlignHCenter
                    text: page.detail
                    wrapMode: Text.WordWrap
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontLead
                    color: theme.muted
                }
            }
        }

        Item { Layout.fillHeight: true }

        RowLayout {
            Layout.fillWidth: true
            spacing: theme.btnGap
            Item { Layout.fillWidth: true }
            UiBtn {
                text: qsTr("Cancel")
                enabledState: page.canCancel && !page.complete
                onClicked: page.cancelRequested()
            }
        }
    }
}
