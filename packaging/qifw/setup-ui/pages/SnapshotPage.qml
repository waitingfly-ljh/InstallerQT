// SnapshotPage.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// Pre-install snapshot screen (maintenance flows only: repair / upgrade / downgrade).
//
// The maintenance screens promise "a recoverable snapshot is created before installation", so this page is
// the explicit step where the user names it and decides whether to take it. It follows the same content
// grammar as the other wizard pages (24px brand title, 16px lead, 16px section labels, one 139px tinted
// card, 34px field, action row pinned to the bottom) so it reads as part of the same design rather than a
// new dialog style. The field/hint pair mirrors the reference rules for snapshot names: starts with a
// letter, letters / digits / - _ . only, 1-65 characters.
Item {
    id: page
    UiTheme { id: theme }

    width: theme.contentW
    height: theme.contentH

    // What the maintenance run will do, so the primary button reads the same as on the maintenance page.
    property string mode: "upgrade"                  // repair | upgrade | downgrade
    property string currentVersion: ""
    property string targetVersion: ""
    property string installDir: ""
    // The snapshot is on by default: it is the safety net the maintenance page promises.
    property bool snapshotEnabled: true
    property string snapshotName: ""
    // Name shown in the field; not refilled from snapshotName while the user is typing (same rule as the
    // install-location field: the echoed normalized value would rewrite the caret position).
    property bool nameEditing: false

    signal nameChanged(string name)
    signal enabledToggled(bool enabled)
    signal backRequested()
    signal proceedRequested()

    readonly property string primaryText: mode === "repair" ? qsTr("Start repair")
                                        : mode === "upgrade" ? qsTr("Start upgrade")
                                        : qsTr("Confirm and downgrade")
    // Snapshot contents (design: the maintenance page's "kept data" card uses the same 2x3 grid).
    readonly property var contents: [
        qsTr("Program files"), qsTr("Custom presets"), qsTr("Software preferences"),
        qsTr("Calibration results"), qsTr("Printer info"), qsTr("LAN access code")
    ]

    readonly property bool nameValid: Host.engine.isValidSnapshotName(page.snapshotName)
    readonly property bool nameTaken: page.nameValid && Host.engine.snapshots.some(s => s.name === page.snapshotName)
    readonly property string nameProblem: !page.snapshotEnabled ? ""
                                        : page.snapshotName.length === 0 ? qsTr("Please enter a snapshot name")
                                        : page.nameTaken ? qsTr("A snapshot with this name already exists")
                                        : !page.nameValid ? qsTr("Start with a letter; letters, digits and - _ . only (1-65 characters)")
                                        : ""
    readonly property bool canProceed: !page.snapshotEnabled || page.nameProblem.length === 0
    // Estimated size of what the snapshot copies (program directory + roaming user data).
    readonly property real estimateBytes: Host.directoryBytes(page.installDir)
                                          + Host.directoryBytes(Host.userDataDirectory(true))

    function fmtBytes(n) {
        const gb = n / (1024 * 1024 * 1024)
        return gb >= 1 ? gb.toFixed(1) + " GB" : Math.max(1, Math.round(n / (1024 * 1024))) + " MB"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("Create a snapshot")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.Bold
            color: theme.brand
        }
        Item { Layout.preferredHeight: 6 }

        Text {
            Layout.fillWidth: true
            text: qsTr("The current program and your data are backed up first, so a failed %1 can be restored.")
                      .arg(page.mode === "repair" ? qsTr("repair")
                           : page.mode === "upgrade" ? qsTr("upgrade") : qsTr("downgrade"))
            wrapMode: Text.WordWrap
            lineHeight: 1.5
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.textBody
        }

        Item { Layout.preferredHeight: 18 }

        // What the snapshot contains (same card grammar as the maintenance page's kept-data card).
        Text {
            text: qsTr("Snapshot contents")
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSection
            font.weight: Font.DemiBold
            color: theme.text
        }
        Item { Layout.preferredHeight: 8 }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 139
            Layout.minimumHeight: 139
            Layout.maximumHeight: 139
            radius: theme.radiusCard
            color: theme.cardBlue
            border.width: 1
            border.color: theme.cardBlueLine

            Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.topMargin: 17
                spacing: 6

                Text {
                    text: qsTr("Backed up from version %1").arg(page.currentVersion.length > 0
                                                                ? page.currentVersion : qsTr("Unknown"))
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSection
                    font.weight: Font.DemiBold
                    color: theme.text
                }
                Text {
                    text: qsTr("It is restored on the maintenance screen if you need it.")
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSmall
                    color: theme.textBody
                }

                Grid {
                    width: parent.width
                    columns: 2
                    columnSpacing: 0
                    rowSpacing: 4
                    Repeater {
                        model: page.contents
                        delegate: Row {
                            required property string modelData
                            width: 240
                            height: 24
                            spacing: 8
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "✓"
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                font.weight: Font.Bold
                                color: theme.brand
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                color: theme.textBody
                            }
                        }
                    }
                }
            }
        }

        Item { Layout.preferredHeight: 16 }

        Text {
            text: qsTr("Snapshot name")
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSection
            font.weight: Font.DemiBold
            color: theme.snapshotEnabled ? theme.text : theme.mutedSoft
        }
        Item { Layout.preferredHeight: 8 }

        // Name field: same 34px control as the install location field.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: theme.fieldH
            radius: theme.radiusField
            color: page.snapshotEnabled ? theme.card : theme.panelSoft
            border.width: 1
            border.color: !page.snapshotEnabled ? theme.lineSoft
                          : nameInput.activeFocus ? theme.brand : page.nameProblem.length > 0 ? theme.danger : theme.fieldLine

            TextInput {
                id: nameInput
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                verticalAlignment: TextInput.AlignVCenter
                selectByMouse: true
                enabled: page.snapshotEnabled
                font.family: theme.fontFamily
                font.pixelSize: theme.fontBody
                color: page.snapshotEnabled ? theme.text : theme.muted
                selectionColor: theme.brandSoft
                selectedTextColor: theme.text
                clip: true
                text: page.nameEditing ? text : page.snapshotName
                onTextEdited: {
                    page.nameEditing = true
                    page.nameChanged(text)
                }
                onEditingFinished: {
                    page.nameEditing = false
                    page.nameChanged(text)
                }
            }
        }

        Item { Layout.preferredHeight: 6 }

        Text {
            Layout.fillWidth: true
            // Destination folder only: the name is already in the field above, and appending it makes the
            // hint wrap onto three lines.
            text: page.nameProblem.length > 0
                  ? page.nameProblem
                  : qsTr("Saved to %1 (about %2).")
                        .arg(Host.engine.snapshotRoot)
                        .arg(page.fmtBytes(page.estimateBytes))
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSmall
            color: page.nameProblem.length > 0 ? theme.danger : theme.muted
        }

        Item { Layout.preferredHeight: 12 }

        UiCheck {
            text: qsTr("Create a snapshot before installation")
            checked: page.snapshotEnabled
            onToggled: {
                page.enabledToggled(!page.snapshotEnabled)
            }
        }

        Item { Layout.fillHeight: true }

        RowLayout {
            Layout.fillWidth: true
            spacing: theme.btnGap
            Item { Layout.fillWidth: true }
            UiBtn { text: qsTr("Back"); chevron: "left"; onClicked: page.backRequested() }
            UiBtn {
                text: page.primaryText
                primary: true
                enabledState: page.canProceed
                onClicked: page.proceedRequested()
            }
        }
    }
}
