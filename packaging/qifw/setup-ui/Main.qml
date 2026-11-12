// Main.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import SetupUi

// Shell main window: fixed 960x540 (11-11 design), frameless, switches pages based on controller state.
// The controller is created by App.qml / QmlSmoke and its object is assigned to this window's ctl (assignment only; no required declaration needed here); this file only handles the window shell and page assembly.
ApplicationWindow {
    id: window
    objectName: "mainWindow"
    // The controller is created and injected by the outer layer's (App.qml / QmlSmoke) required property: the outer layer first provides a placeholder object,
    // then swaps in the real controller after construction completes; pages read the placeholder value before the real controller arrives, never null.
    //
    // Declaration position: QML bindings resolve by name and are independent of declaration position; it is placed before the reference point only for readability.
    readonly property SetupController ctl: rootCtl.obj

    // Switch from placeholder to the real controller: the outer layer calls bindController() to swap after construction ends.
    QtObject {
        id: rootCtl
        property QtObject obj: placeholderCtl
    }

    function bindController(controller) { rootCtl.obj = controller }

    // Placeholder controller: same type and defaults as the real controller; pages reading it before the real controller is injected do not error.
    readonly property SetupController placeholderCtl: SetupController { }
    UiTheme { id: theme }
    visible: true
    // The design is a fixed-size wizard; the illustration panel and the content column are laid out
    // for exactly 960x540, so the window does not resize.
    width: theme.windowW
    height: theme.windowH
    minimumWidth: theme.windowMinW
    maximumWidth: theme.windowMinW
    minimumHeight: theme.windowMinH
    maximumHeight: theme.windowMinH
    title: qsTr("OrbbecSlicer Setup Wizard")
    flags: Qt.Window | Qt.FramelessWindowHint
    // Transparent window: AppFrame clips the shell to the design's 16px rounded corners, so the
    // pixels outside that shape must stay transparent instead of showing a square window color.
    color: "transparent"

    onClosing: (close) => {
        // Closing is not allowed while installing/uninstalling: let the engine finish or cancel it.
        if (Host.engine.busy)
            close.accepted = false
    }

    // Close confirmation: direct exit is not allowed while installing.
    function requestClose() {
        if (Host.engine.busy)
            return
        Qt.quit()
    }

    // A frameless window has no system title bar: the shell draws the 480px illustration panel (drag area)
    // and the content panel; the window buttons live in AppFrame's top-right corner.
    // Pages are injected through `content` (not the default property, see AppFrame.qml).
    AppFrame {
        anchors.fill: parent

        // The frame only emits the intent: the window owns the actual close/minimize (a frameless
        // window cannot rely on the system buttons, and closing has to respect the engine's busy
        // state), so both signals must be wired here or the drawn buttons do nothing.
        onCloseRequested: window.requestClose()
        onMinimizeRequested: window.showMinimized()

        content: [
            StackLayout {
                id: pageStack
                anchors.fill: parent
                currentIndex: ctl.viewIndex

                // ---- Fresh install: welcome ----
                WelcomePage {
                    onNextRequested: ctl.nextFromWelcome()
                    onCancelRequested: window.requestClose()
                }

                // ---- Fresh install: license ----
                LicensePage {
                    accepted: ctl.licenseAccepted
                    onAcceptToggled: (v) => ctl.licenseAccepted = v
                    onNextRequested: ctl.nextFromLicense()
                    onBackRequested: ctl.backFromLicense()
                    onCancelRequested: window.requestClose()
                }

                // ---- Install options ----
                OptionsPage {
                    id: optionsPage
                    objectName: "optionsPage"
                    installParentDir: ctl.installOptions.installParentDir
                    shortcutDesktop: ctl.installOptions.shortcutDesktop
                    assoc3mf: ctl.installOptions.assoc3mf
                    assocStl: ctl.installOptions.assocStl
                    launchAfterInstall: ctl.installOptions.launchAfterInstall
                    notice: ctl.cancelled ? qsTr("Installation was cancelled; written files have been removed.") : ""
                    onDirChanged: (d) => ctl.installOptions.installParentDir = d
                    onOptionChanged: (key, value) => ctl.installOptions[key] = value
                    onBackRequested: ctl.backFromOptions()
                    onCancelRequested: window.requestClose()
                    onInstallRequested: {
                        // When the user types without pressing Enter and then clicks Install, the input text was already synced via onDirChanged;
                        // syncing once more here ensures the controller gets the intended install location.
                        ctl.installOptions.installParentDir = optionsPage.installParentDir
                        ctl.beginInstall()
                    }
                }

                // ---- Maintenance: Repair / Upgrade / Downgrade ----
                MaintenancePage {
                    mode: ctl.mode === "fresh" ? "repair" : ctl.mode
                    currentVersion: ctl.installed.version
                    targetVersion: ctl.targetVersion
                    riskAcknowledged: ctl.riskAcknowledged
                    onRiskToggled: (c) => ctl.riskAcknowledged = c
                    onCancelRequested: window.requestClose()
                    onProceedRequested: {
                        ctl.installOptions.installDir = Host.normalizeDirPath(ctl.installed.installDir)
                        ctl.installOptions.installParentDir = Host.installParentDirForDir(ctl.installed.installDir)
                        // Maintenance always walks through the snapshot screen first (it is what the
                        // "recoverable snapshot" promise on this page refers to).
                        ctl.beginMaintenance()
                    }
                    onRestoreRequested: ctl.openRollback()
                }

                // ---- Installing (the failure dialog is drawn on top of this page) ----
                ProgressPage {
                    progress: ctl.displayProgress
                    complete: ctl.finishing
                    heading: ctl.uninstalling ? qsTr("Uninstalling OrbbecSlicer")
                               : ctl.runMode === "repair" ? qsTr("Repairing OrbbecSlicer")
                               : ctl.runMode === "upgrade" ? qsTr("Upgrading OrbbecSlicer")
                               : ctl.runMode === "downgrade" ? qsTr("Downgrading OrbbecSlicer")
                               : qsTr("Installing OrbbecSlicer")
                    lead: ctl.uninstalling ? qsTr("Removing program files, please keep this window open.")
                                         : qsTr("Please keep this window open. The installation does not upload local projects or user presets.")
                    onCancelRequested: Host.engine.cancel()
                }

                // ---- Install/Maintenance complete ----
                CompletePage {
                    title: ctl.runMode === "repair" ? qsTr("Repair complete")
                             : ctl.runMode === "upgrade" ? qsTr("Upgrade complete")
                             : ctl.runMode === "downgrade" ? qsTr("Downgrade complete")
                             : qsTr("Installation complete")
                    description: ctl.runMode === "repair" ? qsTr("Repair complete; existing settings remain usable.")
                                   : ctl.runMode === "upgrade" ? qsTr("Upgrade complete; compatible settings were migrated.")
                                   : ctl.runMode === "downgrade" ? qsTr("Downgrade complete; the previous program can be restored from the backup.")
                                   : qsTr("OrbbecSlicer is ready.")
                    primaryText: qsTr("Launch now")
                    onPrimaryAction: {
                        if (!Host.launchApp(ctl.installOptions.installDir.length
                                            ? ctl.installOptions.installDir : ctl.installed.installDir)) {
                            Qt.quit()
                        }
                    }
                }

                // ---- Uninstall: data scope ----
                DataScopePage {
                    removeAllData: ctl.removeAllData
                    onModeSelected: (removeAll) => ctl.removeAllData = removeAll
                    onNextRequested: ctl.view = "confirm"
                    onCancelRequested: window.requestClose()
                }

                // ---- Uninstall: confirmation ----
                UninstallConfirmPage {
                    removeAllData: ctl.removeAllData
                    keepDataDir: ctl.keepDataDir
                    installDir: ctl.installed.installDir
                    onKeepDataDirToggled: (c) => ctl.keepDataDir = c
                    onBackRequested: ctl.view = "dataScope"
                    onConfirmRequested: ctl.beginUninstall()
                }

                // ---- Uninstall complete ----
                CompletePage {
                    title: qsTr("Uninstall complete")
                    description: ctl.removeAllData
                               ? qsTr("Program files have been removed; local application data was purged.")
                               : qsTr("Program files have been removed; personal presets and preferences were retained.")
                    // 80px tinted note under the description (design: 卸载完成 card at 313..392).
                    cardTitle: qsTr("Sensitive credentials cleared")
                    cardBody: qsTr("Login tokens, cloud service credentials and LAN access codes have been removed from this machine.")
                    primaryText: qsTr("Finish")
                    secondaryText: qsTr("View files")
                    showSecondary: ctl.keepDataDir
                    onPrimaryAction: Qt.quit()
                    onSecondaryAction: Host.revealLogs()
                }

                // ---- Maintenance: pre-install snapshot (index 9, appended so the indices above stay stable) ----
                SnapshotPage {
                    mode: ctl.mode === "fresh" ? "repair" : ctl.mode
                    currentVersion: ctl.installed.version
                    targetVersion: ctl.targetVersion
                    installDir: ctl.installed.installDir
                    snapshotEnabled: ctl.snapshotEnabled
                    snapshotName: ctl.snapshotName
                    onNameChanged: (n) => ctl.snapshotName = n
                    onEnabledToggled: (on) => ctl.snapshotEnabled = on
                    onBackRequested: ctl.backFromSnapshot()
                    onProceedRequested: ctl.beginInstall()
                }
            }
        ]
    }

    // Failure dialog: a modal popup over the current screen (design: 配置迁移失败 popup), not a separate
    // page. Declared as a sibling of AppFrame so it keeps its own full-window geometry.
    ErrorDialog {
        anchors.fill: parent
        open: ctl.view === "failure"
        title: ctl.failureTitle
        message: ctl.failureMessage
        code: ctl.failureCodeText
        steps: ctl.failureSteps
        onRetryRequested: ctl.retry()
        onCancelRequested: window.requestClose()
    }

    // Rollback dialog: restores a pre-install snapshot from the maintenance screen (design: 回滚数据).
    RollbackDialog {
        anchors.fill: parent
        open: ctl.rollbackOpen
        snapshots: ctl.snapshots
        selectedName: ctl.rollbackName
        errorText: ctl.rollbackError
        onCancelRequested: ctl.rollbackOpen = false
        onConfirmRequested: ctl.confirmRollback()
    }
}