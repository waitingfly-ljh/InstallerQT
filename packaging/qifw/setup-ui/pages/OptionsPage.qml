// OptionsPage.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import SetupUi

// Install options page: directory, space notice, four options, install button.
// Layout matches the other pages: one full ColumnLayout fills the content area, and the button row follows the content, right-aligned
// (design mockup .setup-actions: justify-content: flex-end).
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
    width: page.contentW
    height: page.contentH

    property real requiredBytes: 1.8 * 1024 * 1024 * 1024   // Matches the design mockup "About 1.8 GB required"
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

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("Install options")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.DemiBold                  // .setup-view h2 { font-weight: 650 }
            color: theme.text
        }
        // Lead copy (.setup-view .lead { margin: 9px 0 24px }: 9 above, 24 below)
        Item { Layout.preferredHeight: 9 }
        Text {
            Layout.fillWidth: true
            text: qsTr("Choose the install location and common options. The app is installed into an OrbbecSlicer folder under the selected folder.")
            wrapMode: Text.WordWrap
            lineHeight: 1.7
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.muted
        }
        Item { Layout.preferredHeight: 24 }
        // Notice after cancelling installation (the design mockup has only a lead; extra page state uses one line of text under the lead;
        // no 34px notice bar any more, so the whole page is not pushed down 48px and the vertical rhythm in screenshots matches the mockup).
        Text {
            visible: page.notice.length > 0
            Layout.fillWidth: true
            Layout.topMargin: 4
            text: page.notice
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontBody
            color: theme.warningInk
        }

        Text {
            text: qsTr("Install location")
            font.family: theme.fontFamily
            font.pixelSize: theme.fontBody
            font.weight: Font.DemiBold                  // .form-label { font-weight: 600 }
            color: theme.text
        }
        Item { Layout.preferredHeight: 7 }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            // Directory input field inline: UiField is a thin wrapper of "input field + alias", so the page needs only one instance.
            Rectangle {
                id: dirField
                Layout.fillWidth: true
                implicitHeight: 38
                radius: theme.radius
                color: theme.panel
                border.width: 1
                border.color: dirInput.activeFocus ? theme.brand : theme.line
                TextInput {
                    id: dirInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    selectByMouse: true
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    color: theme.text
                    selectionColor: theme.brandSoft
                    selectedTextColor: theme.text
                    // Normally follows dirText; not refilled while the user is editing (see dirEditing).
                    // The refill writes text, not a binding: the binding breaks when dirEditing becomes true, and afterwards
                    // OptionsPage's onInstallParentDirChanged, EditingFinished and the folder dialog do the refill.
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
            }
            UiBtn {
                text: qsTr("Browse")
                implicitHeight: 38               // Same height as the directory field (design mockup .path-row both cells equal; button default 36)
                onClicked: folderPicker.open()
            }
        }
        Item { Layout.preferredHeight: 7 }

        // Actual on-disk location: the UI collects the parent folder and the program composes the final directory, so show it permanently here
        // to avoid any doubt about "where exactly it will be installed".
        Text {
            Layout.fillWidth: true
            visible: page.effectiveInstallDir.length > 0
            text: qsTr("Installing to: %1").arg(page.effectiveInstallDir)
            elide: Text.ElideMiddle
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSmall
            color: theme.muted
        }
        Item { Layout.preferredHeight: 4 }

        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSmall
            color: (page.dirProblem.length > 0 && page.installParentDir.length > 0) ? theme.danger
                 : page.spaceShort ? theme.warning
                 : !Host.payloadReady ? theme.warning : theme.muted
            text: {
                // Directory problems take priority over the development-mode payload notice: the user needs to see "this location cannot be used".
                if (page.installParentDir.length > 0 && page.dirProblem.length > 0)
                    return page.dirProblem
                if (page.spaceShort)
                    return qsTr("Only %1 left on this disk, %2 required.").arg(page.fmtBytes(page.free)).arg(page.fmtBytes(page.requiredBytes))
                if (!Host.payloadReady && Host.mode === "development")
                    return qsTr("Development mode: no installer package specified. Start with --payload <path>")
                return qsTr("About %1 of free space required; %2 currently available.").arg(page.fmtBytes(page.requiredBytes)).arg(page.fmtBytes(page.free))
            }
        }

        // Four install options in two columns (design mockup .check-grid { gap: 10px 16px; margin-top: 18px }).
        // Each item = 16px checkbox + label; clicking the whole row toggles it.
        Grid {
            Layout.topMargin: 18
            columns: 2
            columnSpacing: 56
            rowSpacing: 0
            Repeater {
                // Rebuild only when the model changes: if model is written as an inline array literal, QML rebuilds the checkboxes and clears hover state
                // every time the binding is re-evaluated (for example when a diagnostics property changes).
                model: [
                    { "key": "shortcutDesktop", "label": qsTr("Create a desktop shortcut") },
                    { "key": "assoc3mf", "label": qsTr("Associate .3mf files") },
                    { "key": "assocStl", "label": qsTr("Associate .stl files") },
                    { "key": "launchAfterInstall", "label": qsTr("Launch the app after installation") }
                ]
                delegate: Item {
                    id: optionRow
                    required property var modelData
                    readonly property bool checked: page[modelData.key] === true
                    // .check-row row height 1.45 × 13px ≈ 19px, plus .check-grid's 10px row gap.
                    implicitHeight: 29
                    implicitWidth: optionLabel.implicitWidth + 26
                    function toggle() {
                        const v = !checked
                        page.optionChanged(modelData.key, v)
                        page[modelData.key] = v
                    }
                    Rectangle {
                        width: 16; height: 16; radius: 3
                        anchors.verticalCenter: parent.verticalCenter
                        border.width: 1
                        border.color: optionRow.checked ? theme.brand : theme.line
                        color: optionRow.checked ? theme.brand : theme.panel
                        Text {
                            anchors.centerIn: parent
                            visible: optionRow.checked
                            text: "✓"
                            color: theme.white
                            font.pixelSize: 11
                            font.bold: true
                        }
                    }
                    Text {
                        id: optionLabel
                        anchors.left: parent.left
                        anchors.leftMargin: 24
                        anchors.verticalCenter: parent.verticalCenter
                        text: optionRow.modelData.label
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.text
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: optionRow.toggle()
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

        // Action row pinned to the bottom (design mockup .setup-actions { margin-top:auto; padding-top:22px })
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 22
            spacing: 9
            Item { Layout.fillWidth: true }
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
