// UninstallConfirmPage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Uninstall 2/3: confirmation, the two 80px note cards and the keep-user-data checkbox.
//
// Measured on 确认卸载: title ink 41..64, lead ink 78..93, card 1 140..219 (#fff7e9 warning wash,
// title "personal presets are kept" + 12px body), card 2 236..315 (#f2f9f9 + brand border,
// "not affected"), then the action row at 476..519 with the danger button at 817..938.
// The keep-data checkbox is not part of that frame; it sits in the empty band between the cards and
// the action row so the feature is kept without disturbing the measured geometry.
Item {
    id: page

    UiTheme { id: theme }
    width: theme.contentW
    height: theme.contentH
    property bool removeAllData: false
    property bool keepDataDir: false
    property string installDir: ""
    signal keepDataDirToggled(bool checked)
    signal backRequested()
    signal confirmRequested()

    readonly property string cardTitle: page.removeAllData
        ? qsTr("Delete all application data on this machine")
        : qsTr("Personal presets and preferences will be kept")
    readonly property string cardBody: page.removeAllData
        ? qsTr("Presets, calibration results, preferences and device info are deleted as well.")
        : qsTr("Login tokens, cloud service credentials, LAN access codes and caches will be cleared.")

    // Vertical rhythm in ink units (content column starts at window y=36, so page y = window y - 36).
    Column {
        width: parent.width
        spacing: 0

        Item { width: 1; height: 5 }
        Item {
            width: parent.width
            height: 24
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: qsTr("Confirm uninstall")
                elide: Text.ElideRight
                font.family: theme.fontFamily
                font.pixelSize: theme.fontTitle
                font.weight: theme.fontTitleWeight
                color: theme.brand
            }
        }
        Item { width: 1; height: 13 }
        Item {
            width: parent.width
            height: 16
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: qsTr("Confirm the data scope.")
                elide: Text.ElideRight
                font.family: theme.fontFamily
                font.pixelSize: theme.fontLead
                color: theme.textBody
            }
        }

        Item { width: 1; height: 46 }
        UiNoteCard {
            width: parent.width
            // Height follows the body: 80 for the design's one-line copy, one line more in English.
            height: implicitHeight
            warn: true
            title: page.cardTitle
            body: page.cardBody
        }
        Item { width: 1; height: 16 }
        UiNoteCard {
            width: parent.width
            height: implicitHeight
            title: qsTr("Not affected")
            body: qsTr("Projects and exported files outside the program directory, plus cloud data for the current account.")
        }

        // Keep-data checkbox (16px box, 2px brand ring = the design's emphasised variant). It is not
        // part of the 确认卸载 frame; it sits in the empty band between the cards and the action row.
        Item { width: 1; height: 20 }
        UiCheck {
            strong: true
            width: parent.width
            text: qsTr("Keep the user data folder")
            checked: page.keepDataDir
            onToggled: page.keepDataDirToggled(!page.keepDataDir)
        }
    }

    // Action row pinned to the bottom (design: 475..520, back on the left, danger button right).
    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: theme.btnGap
        UiBtn { text: qsTr("Back"); chevron: "left"; onClicked: page.backRequested() }
        Item { Layout.fillWidth: true }
        UiBtn {
            text: qsTr("Confirm uninstall")
            danger: true
            onClicked: page.confirmRequested()
        }
    }
}
