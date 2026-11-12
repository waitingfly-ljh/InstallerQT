// SnapshotPage.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// Pre-install snapshot screen (maintenance flows only: repair / upgrade / downgrade).
//
// The maintenance screens promise "a recoverable snapshot is created before installation", so this page
// is the explicit step where the user names it and decides whether to take it.
//
// Geometry from the 创建快照 frame (measured; the content column starts at window y=36, so page y =
// window y - 36):
//   title ink   41..64                 -> page   5..28
//   label       94..109                -> page  58..73
//   43px field 123.5..166.5            -> page  87.5..130.5  (1px #f5f5f5 outline, rx9.5, 10px inset)
//   label      181..196 / 268..283     -> page 145..160 / 232..247   (field pitch 87px)
//   hint ink   349..365 (12px, #a5a5a5)-> page 313..329
//   label      381..396                -> page 345..360
//   radio row  410..435 (d25)          -> page 374..399
//   button     476..519                -> page 440..483
// The frame has one primary button and no footer navigation; "Back" is kept at the left as a
// functional deviation (the page is only reachable from the maintenance screen).
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

    Column {
        width: parent.width
        spacing: 0

        Item {
            width: parent.width
            height: 24
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: qsTr("Create a snapshot")
                elide: Text.ElideRight
                font.family: theme.fontFamily
                font.pixelSize: theme.fontTitle
                font.weight: theme.fontTitleWeight
                color: theme.brand
            }
        }

        // --- Group 1: current version (read only) ---
        Item { width: 1; height: 31 }
        Item {
            width: parent.width
            height: 16
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: qsTr("Installed version")
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSection
                font.weight: Font.DemiBold
                color: theme.textStrong
            }
        }
        Item { width: 1; height: 16.5 }
        UiSelect {
            width: parent.width
            readOnly: true
            text: page.currentVersion.length > 0 ? page.currentVersion : qsTr("Unknown")
        }

        // --- Group 2: install location (read only) ---
        Item { width: 1; height: 11.5 }
        Item {
            width: parent.width
            height: 16
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: qsTr("Install location")
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSection
                font.weight: Font.DemiBold
                color: theme.textStrong
            }
        }
        Item { width: 1; height: 16.5 }
        UiSelect {
            width: parent.width
            readOnly: true
            elideMode: Text.ElideMiddle
            text: page.installDir
        }

        // --- Group 3: snapshot name ---
        Item { width: 1; height: 11.5 }
        Item {
            width: parent.width
            height: 16
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: qsTr("Snapshot name")
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSection
                font.weight: Font.DemiBold
                color: page.snapshotEnabled ? theme.textStrong : theme.mutedSoft
            }
        }
        Item { width: 1; height: 16.5 }
        UiField {
            width: parent.width
            focused: nameInput.activeFocus
            disabled: !page.snapshotEnabled
            danger: page.snapshotEnabled && page.nameProblem.length > 0

            TextInput {
                id: nameInput
                anchors.fill: parent
                verticalAlignment: TextInput.AlignVCenter
                selectByMouse: true
                enabled: page.snapshotEnabled
                font.family: theme.fontFamily
                font.pixelSize: theme.fontBody
                color: page.snapshotEnabled ? theme.textStrong : theme.muted
                selectionColor: theme.brandSoft
                selectedTextColor: theme.textStrong
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
                // Placeholder copy (design: #b7b7b7, e.g. "snapshot202007083053").
                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: nameInput.text.length === 0
                    text: qsTr("For example: snapshot20200708")
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    color: theme.textPlaceholder
                }
            }
        }

        // Hint line: name rules while the field is being edited, otherwise where the snapshot goes.
        Item { width: 1; height: 6 }
        Item {
            width: parent.width
            height: 16
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: page.nameProblem.length > 0
                      ? page.nameProblem
                      : qsTr("Saved to %1 (about %2).")
                            .arg(Host.engine.snapshotRoot)
                            .arg(page.fmtBytes(page.estimateBytes))
                elide: Text.ElideRight
                font.family: theme.fontFamily
                font.pixelSize: theme.fontHint
                color: page.nameProblem.length > 0 ? theme.danger : theme.textFaint
            }
        }

        // --- Take it or not (design: 14px label + a d25 radio row) ---
        Item { width: 1; height: 15 }
        Item {
            width: parent.width
            height: 16
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: qsTr("Create a snapshot before installation")
                elide: Text.ElideRight
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSection
                font.weight: Font.DemiBold
                color: theme.textStrong
            }
        }
        Item { width: 1; height: 16.5 }

        Row {
            width: parent.width
            height: theme.radioSizeLg
            spacing: 0

            Repeater {
                model: [
                    { "enabled": true,  "label": qsTr("Create") },
                    { "enabled": false, "label": qsTr("Do not create") }
                ]
                delegate: UiRadio {
                    id: radioSlot
                    required property var modelData
                    width: 142
                    height: theme.radioSizeLg
                    compact: false
                    text: radioSlot.modelData.label
                    checked: page.snapshotEnabled === radioSlot.modelData.enabled
                    onToggled: {
                        if (page.snapshotEnabled !== radioSlot.modelData.enabled)
                            page.enabledToggled(radioSlot.modelData.enabled)
                    }
                }
            }
        }
    }

    // Action row: the frame has a single 124x44 button at 816..939 with no footer navigation.
    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: theme.btnGap
        UiBtn { text: qsTr("Back"); chevron: "left"; onClicked: page.backRequested() }
        Item { Layout.fillWidth: true }
        UiBtn {
            text: page.primaryText
            primary: true
            enabledState: page.canProceed
            onClicked: page.proceedRequested()
        }
    }
}
