// ProgressPage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Progress page: task name, percentage, progress bar, detail line, cancel.
// Progress comes from Host.engine's real output (phase + events); no fixed animation is played.
//
// Geometry from 安装过程 / 升级过程 / 降级过程 / 卸载过程 (measured; the content column starts at
// window y=36, so page y = window y - 36):
//   title ink     41.5..64.3   -> page   5.5..28.3
//   lead ink      78.5..93.7   -> page  42.5..57.7
//   phase ink    238.2..251.2  -> page 202.2..215.2   (13px #222222)
//   percentage   238.1..250.0  -> page 202.1..214.0   (16px brand, right aligned)
//   track        262..274      -> page 226..238        (442x12 rx6 #EEEEEE, fill fades to 10%)
//   detail ink   290.1..303.2  -> page 254.1..267.2   (13px #A2A2A3)
// The block is placed below the lead, not centred; the action row is pinned to the page bottom.
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

    readonly property int percent: page.complete ? 100 : page.progress

    Text {
        x: 0
        y: 0
        width: parent.width
        text: page.heading
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

    Item {
        id: phaseRow
        x: 0
        y: 197
        width: parent.width
        height: 20

        Text {
            id: percentText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: page.percent + "%"
            font.family: theme.fontFamily
            // Measured: the digits are em≈16 (ink 11.86 high) in brand teal.
            font.pixelSize: theme.fontValue
            color: theme.brand
        }
        Text {
            anchors.left: parent.left
            anchors.right: percentText.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: page.phase
            elide: Text.ElideRight
            font.family: theme.fontFamily
            font.pixelSize: theme.fontBody
            font.weight: Font.DemiBold
            color: theme.text
        }
    }

    Rectangle {
        id: track
        x: 0
        y: 226
        width: parent.width
        height: 12
        radius: 6
        clip: true
        color: theme.track

        Rectangle {
            height: parent.height
            radius: 6
            width: parent.width * Math.max(0, Math.min(1, page.percent / 100))
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: theme.brand }
                GradientStop { position: 1.0; color: theme.trackFillEnd }
            }
            Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        }
    }

    Text {
        x: 0
        y: 250
        width: parent.width
        text: page.detail
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        font.family: theme.fontFamily
        font.pixelSize: theme.fontBody
        color: theme.detailInk
    }

    // Action row pinned to the page bottom (design: y 476..520 of the 540px window).
    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: theme.btnGap
        Item { Layout.fillWidth: true }
        UiBtn {
            text: qsTr("Cancel")
            enabledState: page.canCancel && !page.complete
            onClicked: page.cancelRequested()
        }
    }
}
