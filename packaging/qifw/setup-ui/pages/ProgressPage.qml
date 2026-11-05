// ProgressPage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Progress page: task name, percentage, progress bar, detail line, cancel.
// Progress comes from Host.engine's real output (phase + events); no fixed animation is played.
Item {
    id: page
    UiTheme { id: theme }
    // The page is drawn inside AppFrame's content area (size = window − title bar/side bar/padding). But the
    // parent size the page receives in this construction order is 0 (AppFrame's layout settles a step later, so the page's anchors.fill
    // is not recalculated), and the content area's ColumnLayout therefore lays out to the narrowest row (97px), wrapping
    // early wherever it would wrap. So the layout does not follow parent; it computes the content area from the window size directly. When the window size is unknown
    // (the hidden smoke copy) it falls back to the default 940×650.
    readonly property real contentW: (page.Window.width > 0 ? page.Window.width : theme.windowW)
                                     - theme.sideW - theme.contentPaddingH * 2
    readonly property real contentH: (page.Window.height > 0 ? page.Window.height : theme.windowH)
                                     - theme.titleBarH - theme.contentPaddingV - 24

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
        id: col
        x: 0
        y: 0
        width: page.contentW
        height: page.contentH
        spacing: 0

        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: page.heading
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.DemiBold
            color: theme.text
        }
        // Lead copy (.setup-view .lead { margin: 9px 0 24px }: 9 above, 24 below)
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.fillWidth: true
            text: page.lead
            wrapMode: Text.WordWrap
            lineHeight: 1.7
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.muted
        }
        Item { Layout.preferredHeight: 24 }

        // Design mockup .progress-visual { width: min(500px, 100%); margin: 58px auto 20px }.
        // Centered horizontally, placed below the lead vertically; the cancel row is pushed to the bottom by the fillHeight spacer below.
        // The width takes 50% of the page's actual width (940−228−92 = 620 → 500), unaffected by the layout overriding width.
        Item {
            id: visual
            Layout.fillWidth: true
            Layout.topMargin: 58 + 20              // margin: 58px ... 20px → 58 above = 24 after lead + 34; the 20 below comes from the fillHeight spacer
            Layout.preferredHeight: visualCol.implicitHeight
            Layout.alignment: Qt.AlignHCenter

            Column {
                id: visualCol
                width: Math.min(500, page.contentW)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 9

                // Title row (.progress-title { display:flex; justify-content:space-between; margin-bottom:9px }):
                // task name left, percentage right. Use anchors instead of Row: Row would not leave room for the absolutely positioned percentage.
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

                // .progress-track { height: 9px; border-radius: 20px; background: light gray }
                Rectangle {
                    id: track
                    width: parent.width
                    height: 9
                    radius: 20
                    clip: true
                    color: theme.track

                    Rectangle {
                        height: parent.height
                        radius: 20
                        width: parent.width * Math.max(0, Math.min(1, (page.complete ? 100 : page.progress) / 100))
                        // .progress-fill: linear-gradient(90deg, brand color, brand light color)
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: theme.brand }
                            GradientStop { position: 1.0; color: theme.trackFillEnd }
                        }
                        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    }
                }

                // .progress-detail { margin-top: 11px; text-align: center }
                Text {
                    width: parent.width
                    topPadding: 2                     // column gap 9 + 2 = 11
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
        // Action row pinned to the bottom (design mockup .setup-actions { margin-top:auto; padding-top:22px })
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            Item { Layout.fillWidth: true }
            UiBtn {
                text: qsTr("Cancel")
                enabledState: page.canCancel && !page.complete
                onClicked: page.cancelRequested()
            }
        }
    }
}
