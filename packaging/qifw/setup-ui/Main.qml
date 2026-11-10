// Main.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import SetupUi

// Shell main window: frameless 940×650, switches pages based on controller state.
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
    width: theme.windowW
    height: theme.windowH
    minimumWidth: theme.windowMinW
    minimumHeight: theme.windowMinH
    title: qsTr("OrbbecSlicer Setup Wizard")
    flags: Qt.Window | Qt.FramelessWindowHint
    color: theme.page

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

    // Screenshot mode is triggered in App.qml (after the window is shown and pages are positioned); this file need not know about screenshots.

    // A frameless window has no system title bar: the whole content is drawn by AppFrame (the title bar is draggable).
    // Declared directly here without wrapping in a Loader: ApplicationWindow only puts direct children into contentItem,
    // so a shell created by a Loader is built but never enters the scene, and pages are never instantiated.
    // It must anchor to the full window: ApplicationWindow only gives direct children a default position (0,0) and does not set a size,
    // so an unanchored shell is 0×0, the inner layout cannot reach the content area, and pages are never created.
    AppFrame {
        anchors.fill: parent
        windowTitle: ctl.view === "dataScope" || ctl.view === "confirm" || ctl.view === "uninstalled"
                     ? qsTr("Uninstall OrbbecSlicer")
                     : qsTr("OrbbecSlicer Setup Wizard")
        sideHeadline: ctl.view === "dataScope" || ctl.view === "confirm"
                      ? qsTr("Uninstall\nOrbbecSlicer")
                      : qsTr("Let creativity\ntake shape")
        sideFoot: {
            if (ctl.view === "dataScope" || ctl.view === "confirm")
                return qsTr("Uninstalling requires no sign-in\nand no internet connection")
            return qsTr("OrbbecSlicer %1").arg(ctl.targetVersion)
        }
        installSteps: ctl.installSteps
        uninstallSteps: ctl.uninstallSteps
        onMinimizeRequested: window.showMinimized()
        onCloseRequested: window.close()
        style: ctl.uninstalling ? "uninstall" : "install"

        StackLayout {
            id: pageStack
            currentIndex: {
                const v = ctl.view
                if (v === "options") return 0
                if (v === "maintenance") return 1
                if (v === "progress") return 2
                if (v === "complete") return 3
                if (v === "failure") return 4
                if (v === "dataScope") return 5
                if (v === "confirm") return 6
                if (v === "uninstalled") return 7
                return 0
            }

            // Pages compute their content-area size from the window size themselves (see the contentW/contentH notes at the top of each page);
            // here they are only pinned horizontally into the content area, no longer anchors.fill.
            // Page switching uses StackLayout: hidden pages do not participate in layout, only the ctl.view page is shown.

            // ---- Install options ----
            OptionsPage {
                id: optionsPage
                objectName: "optionsPage"
                visible: ctl.view === "options"
                installParentDir: ctl.installOptions.installParentDir
                shortcutDesktop: ctl.installOptions.shortcutDesktop
                assoc3mf: ctl.installOptions.assoc3mf
                assocStl: ctl.installOptions.assocStl
                launchAfterInstall: ctl.installOptions.launchAfterInstall
                notice: ctl.cancelled ? qsTr("Installation was cancelled; written files have been removed.") : ""
                onDirChanged: (d) => ctl.installOptions.installParentDir = d
                onOptionChanged: (key, value) => ctl.installOptions[key] = value
                onInstallRequested: {
                    // When the user types without pressing Enter and then clicks Install, the input text was already synced via onDirChanged;
                    // syncing once more here ensures the controller gets the intended install location.
                    ctl.installOptions.installParentDir = optionsPage.installParentDir
                    ctl.beginInstall()
                }
            }

            // ---- Maintenance: Repair / Update / Downgrade ----
            MaintenancePage {
                visible: ctl.view === "maintenance"
                mode: ctl.mode === "fresh" ? "repair" : ctl.mode
                currentVersion: ctl.installed.version
                targetVersion: ctl.targetVersion
                riskAcknowledged: ctl.riskAcknowledged
                onRiskToggled: (c) => ctl.riskAcknowledged = c
                onCancelRequested: Qt.quit()
                onProceedRequested: {
                    ctl.installOptions.installDir = Host.normalizeDirPath(ctl.installed.installDir)
                    ctl.installOptions.installParentDir = Host.installParentForDir(ctl.installed.installDir)
                    ctl.beginInstall()
                }
            }

            // ---- Installing ----
            ProgressPage {
                visible: ctl.view === "progress"
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
                visible: ctl.view === "complete"
                title: ctl.runMode === "repair" ? qsTr("Repair complete")
                         : ctl.runMode === "upgrade" ? qsTr("Upgrade complete")
                         : ctl.runMode === "downgrade" ? qsTr("Downgrade complete")
                         : qsTr("Installation complete")
                description: ctl.runMode === "repair" ? qsTr("Repair complete; existing settings remain usable.")
                               : ctl.runMode === "upgrade" ? qsTr("Upgrade complete; compatible settings were migrated.")
                               : ctl.runMode === "downgrade" ? qsTr("Downgrade complete; a settings snapshot was retained.")
                               : qsTr("OrbbecSlicer is ready.")
                primaryText: qsTr("Launch now")
                onPrimaryAction: {
                    if (!Host.launchApp(ctl.installOptions.installDir.length
                                        ? ctl.installOptions.installDir : ctl.installed.installDir)) {
                        Qt.quit()
                    }
                }
            }

            // ---- Installation incomplete ----
            FailurePage {
                visible: ctl.view === "failure"
                errorCode: ctl.failureCodeText
                errorText: ctl.failureMessage
                onOpenLogsRequested: Host.revealLogs()
                onRetryRequested: ctl.retry()
            }

            // ---- Uninstall: data scope ----
            DataScopePage {
                visible: ctl.view === "dataScope"
                removeAllData: ctl.removeAllData
                onModeSelected: (removeAll) => ctl.removeAllData = removeAll
                onNextRequested: ctl.view = "confirm"
                onCancelRequested: Qt.quit()
            }

            // ---- Uninstall: confirmation ----
            UninstallConfirmPage {
                visible: ctl.view === "confirm"
                removeAllData: ctl.removeAllData
                keepDataDir: ctl.keepDataDir
                installDir: ctl.installed.installDir
                onKeepDataDirToggled: (c) => ctl.keepDataDir = c
                onBackRequested: ctl.view = "dataScope"
                onConfirmRequested: ctl.beginUninstall()
            }

            // ---- Uninstall complete ----
            CompletePage {
                visible: ctl.view === "uninstalled"
                title: qsTr("Uninstall complete")
                description: ctl.removeAllData
                           ? qsTr("Program files have been removed; local application data was purged.")
                           : qsTr("Program files have been removed; personal presets and preferences were retained.")
                primaryText: qsTr("Finish")
                secondaryText: qsTr("View files")
                showSecondary: ctl.keepDataDir
                onPrimaryAction: Qt.quit()
                onSecondaryAction: Host.revealLogs()
            }
        }
    }
}
