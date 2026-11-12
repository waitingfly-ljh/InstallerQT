pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// Engine entry point: main.cpp loads this file via qrc:/SetupUi/App.qml; Main creates and shows the window.
// The root type is Item (not ApplicationWindow): the window is created and shown by Main itself,
// and this file only holds the single controller instance and connects engine signals.
Item {
    id: app

    // Screenshot build injection (--view <view> / --shot-dir <dir>); both are empty strings in normal launches.
    // main.cpp always injects viewName / shotDir / smokeView / smokeOption; they are QVariant,
    // reading a nonexistent name yields undefined, which stringifies to empty, so they are safe to read in normal builds too.
    // They must be declared near the top of the file: in QML "reading a property declared later in the current scope" is unreliable
    // (an empty string was read in onCompleted). So the host-injected globals viewName / shotDir are bound explicitly here.
    property string viewName: typeof viewNameGlobal !== "undefined" ? viewNameGlobal : ""
    property string shotDir: typeof shotDirGlobal !== "undefined" ? shotDirGlobal : ""
    // --selftest --qml-smoke: mounts QmlSmoke (all pages) on the Loader below.
    readonly property bool smoke: Qt.application.arguments.indexOf("--qml-smoke") >= 0
    function shotPathFor(v, d) {
        return v.length > 0 ? (d.length > 0 ? d + "/" + v + ".png" : v + ".png") : ""
    }
    readonly property string shotPath: shotPathFor(app.viewName, app.shotDir)
    // Screenshot mode (-DORBBEC_SETUP_SHOT build): main.cpp injects shotModel and registers
    // the OrbbecShot.QmlShot singleton. QmlSmoke always loads this file into another placeholder App model;
    // that model is an empty object, so this file's controller follows the normal launch path (and its window stays invisible).
    readonly property bool shotMode: typeof shotModel !== "undefined" && shotModel !== null
                                              && Object.keys(shotModel).length > 0

    // Create the controller before frame 0: screenshot/smoke modes position it from the model, normal launches go through start()
    // (choosing the first screen based on "installed/not installed"). The smoke root object QmlSmoke has its own controller.
    //
    // The controller is deliberately declared as a property rather than an id: an id cannot bind to Main's required property
    // (writing an id into a property value binds that id's "object pointer property"; plain objects lack it, so the whole
    // Main gets null). A SetupController created in the library automatically becomes a child of this object, with unchanged lifetime;
    // externally, app.ctl.view can still be read and written.
    property SetupController ctl: SetupController {
        uninstalling: app.shotMode && shotModel.uninstalling !== undefined ? shotModel.uninstalling : false
        Component.onCompleted: {
            if (!app.shotMode) {
                start()
                return
            }
            if (shotModel.failure !== undefined) {
                failureCode = shotModel.failure
                failureCodeText = String(shotModel.failure)
                failureMessage = shotModel.message || ""
            }
            if (shotModel.view !== undefined)
                view = shotModel.view
            if (shotModel.rollback !== undefined)
                rollbackOpen = shotModel.rollback
        }
    }

    // Smoke root object (--selftest --qml-smoke): declared after the main window so it is created last.
    Loader { id: smokeLoader }


    Connections {
        target: Host.engine
        function onFinished(code, summary) { ctl.onEngineFinished(code, summary) }
        function onCancelled() { ctl.onEngineCancelled() }
    }

    Main {
        id: main
        // Pass only object values: do not use ctl (assigning the same-named id from App to a required property becomes a pointer, and Main reads null).
        Component.onCompleted: bindController(app.ctl)
        // In smoke mode another QmlSmoke is mounted (it has its own visible main window); this one is kept only as a reference.
        visible: !app.smoke
    }

    // Screenshot: QmlSmoke captures in its own window (the screen grab is done in main.cpp's QmlShot singleton).
    //   --selftest --qml-smoke -> QmlSmoke (instantiates all pages, the controller is positioned by --view)
    //   otherwise -> this file launches directly (positioned by shotModel), and the screenshot is done by a path outside QmlSmoke.
    // File name = <--shot-dir>/<--view>.png.
    Component.onCompleted: {
        const png = shotPathFor(app.viewName, app.shotDir)
        // The root object is an Item, so Main as a nested Window is not shown automatically; normal launches call show explicitly.
        if (!app.smoke)
            main.show()
        if (app.smoke) {
            smokeLoader.setSource("qrc:/SetupUi/QmlSmoke.qml", {
                "shotPath": png,
                // The component is only declared, not instantiated: QmlSmoke's own Loader creates it.
                "appFrameComponent": smokeFrameComponent
            })
        }
    }

    Component {
        id: smokeFrameComponent
        // Root is a plain Item (not AppFrame) so the failure dialog can overlay the whole window: every
        // direct child of AppFrame lands in its content host, which would clip the 560px dialog to 440px.
        Item {
            // The smoke component is an independent instance and no longer derives state itself: it accepts the screenshot controller.
            // The options page binds directly to the controller (consistent with Main.qml): --option changes exactly this state,
            // and copying a snapshot would instead yield defaults due to ctl's onCompleted timing.
            property var shotCtl

            AppFrame {
                id: shotFrame
                anchors.fill: parent

                content: [
                StackLayout {
                    anchors.fill: parent
                    // Content area matches Main.qml: shows only the page at the controller's currentIndex.
                    // StackLayout ignores each page's own visible, so showOnly() changes ctl.flowView instead.
                    currentIndex: shotCtl !== undefined ? shotCtl.viewIndex : 0

                    WelcomePage { }
                    LicensePage { accepted: shotCtl !== undefined && shotCtl.licenseAccepted; onAcceptToggled: (v) => {} }
                    OptionsPage {
                        id: optionsPage
                        installParentDir: "C:\\Program Files"
                        shortcutDesktop: true
                        assoc3mf: true
                        assocStl: false
                        launchAfterInstall: true
                        notice: ""
                        onDirChanged: (d) => {}
                        onOptionChanged: (k, v) => {}
                    }
                    MaintenancePage {
                        id: maintenancePage
                        mode: "upgrade"
                        currentVersion: "1.0.0"
                        targetVersion: "1.1.0"
                        riskAcknowledged: false
                        onRiskToggled: (c) => {}
                    }
                    // The progress level is hardcoded in the screenshot component: Host.engine is not running in screenshot mode, so reading it always yields 0%.
                    ProgressPage { id: progressPage; heading: qsTr("Installing OrbbecSlicer"); lead: qsTr("Please keep this window open. The installation does not upload local projects or user presets."); phase: qsTr("Preparing components"); progress: 42; detail: qsTr("Verifying package integrity...") }
                    CompletePage { id: completePage; title: qsTr("Installation complete"); description: qsTr("OrbbecSlicer is ready."); primaryText: qsTr("Launch now"); secondaryText: qsTr("View files"); showSecondary: false }
                    DataScopePage { id: dataScopePage; removeAllData: false }
                    UninstallConfirmPage { id: confirmPage; removeAllData: false; keepDataDir: true; installDir: "C:\\OrbbecSlicer" }
                    CompletePage {
                        id: uninstalledPage
                        title: qsTr("Uninstall complete")
                        description: qsTr("Program files have been removed; personal presets and preferences were retained.")
                        // Same note card as Main.qml's uninstall-complete page (design: card 313..392).
                        cardTitle: qsTr("Sensitive credentials cleared")
                        cardBody: qsTr("Login tokens, cloud service credentials and LAN access codes have been removed from this machine.")
                        primaryText: qsTr("Finish")
                        secondaryText: qsTr("View files")
                        showSecondary: true
                    }
                    SnapshotPage {
                        id: snapshotPage
                        mode: "upgrade"
                        currentVersion: "1.0.0"
                        targetVersion: "1.1.0"
                        installDir: "C:\\Program Files\\OrbbecSlicer"
                        snapshotEnabled: true
                        snapshotName: "snapshot20261111-213045"
                        onNameChanged: (n) => {}
                        onEnabledToggled: (on) => {}
                    }
                }
                ]
            }

            // Failure dialog: same overlay as Main.qml, so --view failure captures the popup over the progress page.
            // The controller has no engine summary in screenshot mode, so a sample sentence stands in for
            // the real hint strip text (layout review only; real launches always pass the engine summary).
            ErrorDialog {
                anchors.fill: parent
                open: shotCtl !== undefined && shotCtl.view === "failure"
                title: shotCtl !== undefined ? shotCtl.failureTitle : qsTr("Installation failed")
                message: shotCtl !== undefined && shotCtl.failureMessage.length > 0
                         ? shotCtl.failureMessage
                         : qsTr("The installation stopped unexpectedly. Files written so far were rolled back; retry or check the environment and try again.")
                code: shotCtl !== undefined ? shotCtl.failureCodeText : ""
                // The error-code skeleton (design 显示错误代码与重试) has no step list: --view failure-code
                // injects noSteps so the same dialog renders skeleton B.
                steps: (shotCtl !== undefined
                        && !(typeof shotModel !== "undefined" && shotModel !== null && shotModel.noSteps === true))
                       ? shotCtl.failureSteps : []
            }

            // Rollback dialog: same overlay as Main.qml (--view rollback). The engine has no snapshots in
            // screenshot mode, so sample rows stand in for the list (layout review only; real launches read
            // Host.engine.snapshots through the controller).
            RollbackDialog {
                anchors.fill: parent
                open: shotCtl !== undefined && shotCtl.rollbackOpen
                snapshots: shotCtl !== undefined && shotCtl.snapshots.length > 0 ? shotCtl.snapshots : [
                    { "name": "snapshot20261111-213045", "version": "1.0.0", "createdAt": "2026-11-11T21:30:45", "bytes": 372000000 },
                    { "name": "snapshot20261109-101323", "version": "0.9.6", "createdAt": "2026-11-09T10:13:23", "bytes": 358000000 }
                ]
                selectedName: shotCtl !== undefined && shotCtl.rollbackName.length > 0
                              ? shotCtl.rollbackName : "snapshot20261111-213045"
                errorText: shotCtl !== undefined ? shotCtl.rollbackError : ""
            }

            // The smoke component is an independent instance and no longer derives state itself: the controller comes from the caller.
            function showOnly(view) {
                if (shotCtl !== undefined)
                    shotCtl.setView(view)
            }
            function applyShotState(state) {
                if (state.ctl === undefined)
                    return
                shotCtl = state.ctl
                // During screenshots --option changes ctl.installOptions, which the page binds to. The page's own
                // dirChanged / optionChanged only fire on user actions and do not trigger during screenshots, so they are not wired back to the controller.
                optionsPage.installParentDir = Qt.binding(() => shotCtl.installOptions.installParentDir)
                optionsPage.shortcutDesktop = Qt.binding(() => shotCtl.installOptions.shortcutDesktop)
                optionsPage.assoc3mf = Qt.binding(() => shotCtl.installOptions.assoc3mf)
                optionsPage.assocStl = Qt.binding(() => shotCtl.installOptions.assocStl)
                optionsPage.launchAfterInstall = Qt.binding(() => shotCtl.installOptions.launchAfterInstall)
                // After applyShotState on the screenshot shell, optionsPage.installParentDir is bound to ctl;
                // the only laggard is "ctl has not yet supplied defaults": ctl's Component.onCompleted runs after the screenshot shell.
                // At that point it is still an empty string, so fall back to the same defaults as SetupController.resetOptions.
                if (shotCtl.installOptions.installParentDir.length === 0) {
                    shotCtl.installOptions.installParentDir = Host.normalizeDirPath(Host.defaultInstallParent())
                    shotCtl.installOptions.installDir = Host.installDirForParent(shotCtl.installOptions.installParentDir)
                }
            }
        }
    }
}
