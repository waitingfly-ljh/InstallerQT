// OptionsPage.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import SetupUi

// Install options (design: 安装设置): location field with an in-field folder button, required-space
// hint, four options in a 2x2 grid, action row pinned to the bottom.
// The page is drawn inside AppFrame's 440x502 content column; the size is taken from the token table
// so the geometry matches the design regardless of when the parent chain settles.
Item {
    id: page
    UiTheme { id: theme }

    width: theme.contentW
    height: theme.contentH

    property real requiredBytes: 1.8 * 1024 * 1024 * 1024   // Matches the design "About 1.8 GB required"
    // The UI collects the parent folder ("where to put the software"); the actual install directory is fixed to the OrbbecSlicer subfolder under it.
    property string installParentDir: ""
    // Normalized form of the actual install directory (C:/x/ → C:\x). The Install button looks only at this.
    readonly property string effectiveInstallDir: Host.installDirForParent(page.installParentDir)
    // Text shown in the input field. Do not bind TextInput.text to installParentDir: that makes every textEdited
    // trigger the "is this a binding loop" check, and the "Binding loop detected" in the log makes capture-ui fail;
    // here the text is driven only by these events: initial construction, installParentDir changing outside editing (controller supplies the default),
    // editing finished, and folder dialog selection.
    property string dirText: ""
    // The user is editing in the input field (after textEdited, before editing finishes or focus is lost). While true the field is
    // not refilled from installParentDir: the normalized path echoed back by the controller would rewrite the intermediate state (trailing slash, lowercase drive letter)
    // and the caret would jump while typing.
    property bool dirEditing: false
    // Refill the input field when installParentDir changes outside editing (controller supplies the default at startup, --option screenshots, etc.).
    // It cannot be written as onInstallParentDirChanged {...}: the same property also has a binding that updates installParentDir
    // (installParentDir: ctl.installOptions.installParentDir), and having both is judged by the QML compiler as
    // "Property value set multiple times", dropping the binding, so use Connections.
    // installParentDir may already have a value at construction (onChanged does not fire), so Component.onCompleted fills it once more.
    Connections {
        target: page
        function onInstallParentDirChanged() { if (!page.dirEditing) page.dirText = page.installParentDir }
    }
    // The controller may already have supplied the default parent folder at construction (onChanged does not fire), so fill it once more.
    Component.onCompleted: page.dirText = page.installParentDir
    property bool shortcutDesktop: true
    property bool assoc3mf: true
    property bool assocStl: false
    property bool launchAfterInstall: true
    property string notice: ""                               // Notice after cancelling installation
    signal installRequested()
    signal backRequested()
    signal cancelRequested()
    signal dirChanged(string dir)
    signal optionChanged(string key, bool value)

    // Directory validation: directory writable + enough space; either failure disables the Install button.
    readonly property string dirProblem: page.effectiveInstallDir.length === 0
                                             ? qsTr("Please enter an install location")
                                             : Host.probeDirectory(page.effectiveInstallDir)
    readonly property real free: Host.freeBytes(page.effectiveInstallDir)
    readonly property bool spaceShort: free >= 0 && free < requiredBytes
    readonly property bool canInstall: dirProblem.length === 0 && !spaceShort && Host.payloadReady
    // For smoke assertions: each checkbox key + whether it is currently checked (order matches the two-column layout in the UI).
    readonly property var optionDiagnostics: [
        { "key": "shortcutDesktop", "checked": page.shortcutDesktop },
        { "key": "assoc3mf", "checked": page.assoc3mf },
        { "key": "assocStl", "checked": page.assocStl },
        { "key": "launchAfterInstall", "checked": page.launchAfterInstall }
    ]

    function fmtBytes(n) {
        if (n < 0) return qsTr("Unknown")
        const gb = n / (1024 * 1024 * 1024)
        return gb >= 1 ? gb.toFixed(1) + " GB" : Math.max(1, Math.round(n / (1024 * 1024))) + " MB"
    }

    // Secondary lines under the option grid: only real problems are shown, so the design's
    // single-line rhythm is kept in the normal case.
    readonly property string statusText: {
        if (page.installParentDir.length > 0 && page.dirProblem.length > 0)
            return page.dirProblem
        if (page.spaceShort)
            return qsTr("Only %1 left on this disk, %2 required.").arg(page.fmtBytes(page.free)).arg(page.fmtBytes(page.requiredBytes))
        if (!Host.payloadReady && Host.mode === "development")
            return qsTr("Development mode: no installer package specified. Start with --payload <path>")
        return ""
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("Install settings")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.Bold
            color: theme.brand
        }
        Item { Layout.preferredHeight: 4 }

        Text {
            Layout.fillWidth: true
            text: qsTr("Confirm the install location and common options.")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.textBody
        }

        // Design rhythm: the settings block starts well below the lead line.
        Item { Layout.preferredHeight: 111 }

        Text {
            text: qsTr("Install location")
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSection
            font.weight: Font.DemiBold
            color: theme.text
        }
        Item { Layout.preferredHeight: 9 }

        // Location field with the folder button inside its right edge (design: one 442px control,
        // 34px tall, #f5f5f5 fill, #d7d7d7 border, grey 43px browse button).
        Rectangle {
            id: dirField
            Layout.fillWidth: true
            implicitHeight: theme.fieldH
            radius: theme.radiusField
            color: theme.card
            border.width: 1
            border.color: dirInput.activeFocus ? theme.brand : theme.fieldLine

            TextInput {
                id: dirInput
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 50
                verticalAlignment: TextInput.AlignVCenter
                selectByMouse: true
                font.family: theme.fontFamily
                font.pixelSize: theme.fontBody
                color: theme.text
                selectionColor: theme.brandSoft
                selectedTextColor: theme.text
                clip: true
                // Normally follows dirText; not refilled while the user is editing.
                text: page.dirEditing ? text : page.dirText
                onTextEdited: {
                    page.dirEditing = true
                    page.dirChanged(text)
                }
                onEditingFinished: {
                    page.dirEditing = false
                    // Refill the input field with the normalized path when editing finishes.
                    page.dirText = page.installParentDir
                }
            }

            // Browse: a light grey block inside the field (design measured 43x34, #e9e9e9) with the
            // outlined folder glyph in brand teal.
            Item {
                id: browse
                width: 43
                height: parent.height
                anchors.right: parent.right
                anchors.rightMargin: 0

                Rectangle {
                    anchors.fill: parent
                    radius: theme.radiusField
                    color: browseMa.containsMouse ? theme.line : theme.fieldBtn
                }
                Rectangle {
                    x: (parent.width - 16) / 2
                    y: (parent.height - 11) / 2 + 1
                    width: 16
                    height: 11
                    radius: 2
                    color: "transparent"
                    border.width: 1.5
                    border.color: browseMa.containsMouse ? theme.brandDark : theme.brand
                }
                Rectangle {
                    x: (parent.width - 16) / 2 + 2
                    y: (parent.height - 11) / 2 - 0.5
                    width: 7
                    height: 4
                    radius: 1
                    color: browseMa.containsMouse ? theme.brandDark : theme.brand
                }
                MouseArea {
                    id: browseMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: folderPicker.open()
                }
            }
        }

        Item { Layout.preferredHeight: 6 }

        // Required space, with the size itself in the brand color (design: 预计需要 1.8 GB 可用空间, 14px).
        Text {
            Layout.fillWidth: true
            textFormat: Text.StyledText
            text: qsTr("About %1 of free space required")
                      .arg("<font color='" + theme.brand + "'>" + page.fmtBytes(page.requiredBytes) + "</font>")
            font.family: theme.fontFamily
            font.pixelSize: theme.fontHint
            color: theme.textBody
        }

        Item { Layout.preferredHeight: 28 }

        // Four install options in two columns (design: column pitch 252px, row pitch 34px).
        Grid {
            id: optionGrid
            columns: 2
            columnSpacing: 12
            rowSpacing: 10

            Repeater {
                // Rebuild only when the model changes: if model is written as an inline array literal, QML rebuilds the checkboxes and clears hover state
                // every time the binding is re-evaluated (for example when a diagnostics property changes).
                model: [
                    { "key": "shortcutDesktop", "label": qsTr("Create a desktop shortcut") },
                    { "key": "assocStl", "label": qsTr("Associate .stl files") },
                    { "key": "assoc3mf", "label": qsTr("Associate .3mf files") },
                    { "key": "launchAfterInstall", "label": qsTr("Launch after installation") }
                ]
                delegate: UiCheck {
                    required property var modelData
                    // Fixed column width so the second column starts at the design's x (252px pitch)
                    // and long translations elide instead of overlapping the neighbour.
                    width: 240
                    height: 24
                    text: modelData.label
                    checked: page[modelData.key] === true
                    onToggled: {
                        const v = !page[modelData.key]
                        page.optionChanged(modelData.key, v)
                        page[modelData.key] = v
                    }
                }
            }

            // Read-only marker for smoke checks (read by main.cpp with --selftest --qml-smoke):
            // every check row has a MouseArea filling the whole row, showing a hand cursor on hover.
            QtObject {
                objectName: "optionDiagnostics"
                readonly property var rows: page.optionDiagnostics
            }
        }

        // Secondary lines live below the grid so the design position of the grid never moves.
        Text {
            Layout.fillWidth: true
            Layout.topMargin: 14
            visible: page.notice.length > 0
            text: page.notice
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSmall
            color: theme.warningInk
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: 8
            visible: page.statusText.length > 0
            text: page.statusText
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSmall
            color: (page.installParentDir.length > 0 && page.dirProblem.length > 0) ? theme.danger : theme.warningInk
        }

        Item { Layout.fillHeight: true }

        // Action row pinned to the bottom (design: buttons at y 476..520 of the 540px window)
        RowLayout {
            Layout.fillWidth: true
            spacing: theme.btnGap
            Item { Layout.fillWidth: true }
            UiBtn { text: qsTr("Back"); chevron: "left"; onClicked: page.backRequested() }
            UiBtn {
                text: qsTr("Install")
                primary: true
                enabledState: page.canInstall
                onClicked: {
                    // End editing first: the focus-loss refill of the normalized path may arrive after the click, so make the directory that is sent
                    // exactly what is visible in the input field (dirChanged was already sent in textEdited).
                    page.dirEditing = false
                    page.installRequested()
                }
            }
        }
    }

    FolderDialog {
        id: folderPicker
        title: qsTr("Choose install folder")
        onAccepted: {
            const p = Host.toNativePath(selectedFolder)
            if (p.length > 0) {
                page.dirEditing = false
                page.dirChanged(p)
                page.dirText = p
            }
        }
    }
}
