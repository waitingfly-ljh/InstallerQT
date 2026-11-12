pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import SetupUi
import OrbbecShot 1.0

// QML smoke test root object: instantiates every component and page so bindings and onCompleted actually run.
// Used only by `--selftest --qml-smoke [--view <view>] [--option <key>]` (the screenshot build also takes screenshots),
// and not created by normal launches.
// One component is injected by App.qml (appFrameComponent); this file only positions things: the main window Main's controller
// is positioned to the screen specified by --view; the shell AppFrame then separately instantiates all pages again (invisible), covering
// the pages that Main does not show.
// SetupController depends on the two context objects Host / SetupEngine; smoke only reads state from them and never calls the engine.
ApplicationWindow {
    id: smoke
    // The smoke root window is itself a window: its children lay out directly into contentItem, sharing the same QQuickRootItem
    // with the screenshot window's ContentItem("QmlSmoke") below. The two 940×650 shell instances are therefore
    // drawn in the same region of the RootItem, and the screenshot includes the lower one too, doubling the text
    // (visible on the options and failure pages). In screenshot mode (shotPath non-empty) the whole window is hidden, leaving only the screenshot window drawing;
    // in normal use the smoke window must be shown for the content to be live.
    visible: smoke.shotPath.length === 0
    width: theme.windowW
    height: theme.windowH

    // Shell injection (--qml-smoke --view <name> --option <key>); defaults to the first screen and the first option.
    // Note: context properties are QVariant; when absent, reading may yield undefined, and reading directly throws
    // "Cannot read property of undefined", so check typeof first before comparing.
    property int optionIndex: (typeof smokeOption !== "undefined" && smokeOption !== null
                               && Number(smokeOption) > 0) ? Number(smokeOption) : 0
    // Output file in screenshot mode; empty means a construction check only, no screenshot.
    property string shotPath: ""
    property Component appFrameComponent

    readonly property string currentView: (typeof smokeView !== "undefined" && smokeView !== null
                                          && smokeView.view !== undefined)
                                          ? smokeView.view : "options"
    readonly property bool currentUninstalling: (typeof smokeView !== "undefined" && smokeView !== null
                                                 && smokeView.uninstalling !== undefined)
                                                 ? smokeView.uninstalling : false
    // Keys of the 4 install options, matching the --option parsing order in main.cpp.
    readonly property var optionKeys: ["shortcutDesktop", "assoc3mf", "assocStl", "launchAfterInstall"]
    // --dir <path>: use another install location for screenshots (e.g. a non-writable / insufficient-space location); defaults to the default directory.
    readonly property string dirOverride: (typeof smokeDir !== "undefined" && smokeDir !== null
                                           && String(smokeDir).length > 0) ? String(smokeDir) : ""

    // Token table and base widgets
    UiTheme { id: theme }
    UiBtn { text: qsTr("OK"); primary: true }
    UiBtn { text: qsTr("Delete"); danger: true }
    UiBtn { text: qsTr("Disabled"); enabledState: false }
    UiCheck { text: qsTr("Checked"); checked: true }
    UiCheck { text: qsTr("Unchecked"); checked: false }
    UiRadio { text: qsTr("Radio checked"); checked: true }
    UiRadio { text: qsTr("Radio compact"); compact: true }
    UiField {
        width: 220
        Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            text: qsTr("Field value")
            font.family: theme.fontFamily
            font.pixelSize: theme.fontBody
        }
    }
    UiSelect { width: 220; model: [qsTr("One"), qsTr("Two")]; currentIndex: 0; text: qsTr("One") }
    BrandMark { base: theme.brand; accent: theme.brandSoft }
    // Skeleton B: no step list, so the code+retry layout is constructed too.
    ErrorDialog {
        message: qsTr("Component check")
        code: "5"
    }
    ErrorDialog {
        steps: [{ "label": qsTr("One"), "state": "done" }, { "label": qsTr("Two"), "state": "failed" },
                { "label": qsTr("Three"), "state": "pending" }]
        message: qsTr("Component check")
    }
    RollbackDialog {
        snapshots: [{ "name": "snapshot-check", "version": "1.0.0", "createdAt": "2026-11-11T21:30:45", "bytes": 1024 }]
        selectedName: "snapshot-check"
        errorText: qsTr("Component check")
    }
    SnapshotPage {
        mode: "upgrade"
        currentVersion: "1.0.0"
        targetVersion: "1.1.0"
        snapshotName: "snapshot-check"
    }

    // Same as App.qml: the controller uses a property rather than an id; Main's required property wants an object property.
    property SetupController ctl: SetupController {
        uninstalling: smoke.currentUninstalling
        Component.onCompleted: {
            view = smoke.currentView
            // --view rollback: the dialog is an overlay on the maintenance page (see main.cpp shotModelFor).
            if (typeof smokeView !== "undefined" && smokeView !== null && smokeView.rollback !== undefined)
                rollbackOpen = smokeView.rollback
            if (smoke.dirOverride.length > 0) {
                installOptions.installParentDir = smoke.dirOverride
                installOptions.installDir = Host.installDirForParent(smoke.dirOverride)
            }
            // During screenshots toggle one option: it writes to the controller's own installOptions (the page binds to it),
            // and applyShotState reads it back from ctl for the screenshot shell.
            if (smoke.optionIndex > 0) {
                const k = smoke.optionKeys[smoke.optionIndex]
                installOptions[k] = !installOptions[k]
            }
        }
    }

    // Main window: visibility is managed by QmlSmoke and it is hidden during smoke (Main's own visible: true binding overrides it).
    Main {
        id: mainWin
        visible: false
        Component.onCompleted: bindController(smoke.ctl)
    }

    // Shell and all pages: constructed once more independently of Main to check each page's bindings; not shown.
    // (Only the copy in the screenshot window is shown.)
    Loader {
        sourceComponent: smoke.appFrameComponent
        onLoaded: {
            item.visible = false
        }
        // Note: this Loader and the screenshot Loader below are not the same object (each has its own onLoaded).
    }

    // Screenshot: reached only after App.qml hands the path to this object.
    // Use appFrameComponent to create one real-size shell (940×650, same size as Main's window),
    // and show it in a real ApplicationWindow: screen capture needs only one on-screen window, because under the entry point
    // `--selftest --qml-smoke` App.qml's Main is hidden.
    ApplicationWindow {
        // The window is sized in visual units: at 125% system scaling a 940×650 window is 1175×813 physical pixels on screen;
        // the content is fixed at 940×650 and fills it exactly (no extra background border). Screenshot size therefore varies with system scaling,
        // and tools/capture-ui.ps1 pins it to 940×650 with QT_SCALE_FACTOR=1, matching Main's window.
        id: shotWindow
        visible: smoke.shotPath.length > 0
        x: 0
        y: 0
        width: theme.windowW
        height: theme.windowH
        color: theme.page
        title: qsTr("OrbbecSlicer Setup Wizard")
        flags: Qt.Window | Qt.FramelessWindowHint

        Loader {
            id: shotLoader
            anchors.fill: parent
            sourceComponent: smoke.appFrameComponent
            onLoaded: {
                // During screenshots keep only the page at ctl.viewIndex (<- --view); see App.qml's showOnly().
                // Option state is not derived here: ctl's Component.onCompleted may run after this Loader,
                // so what is read then is the default. Pages bind directly to ctl.installOptions, no copy needed;
                // the step list is also bound to ctl by applyShotState, following --view.
                item.applyShotState({ "ctl": ctl })
                item.showOnly(smoke.currentView)
                // The screenshot must show the actual on-screen pixels of the "940×650 window": the window is scaled up by dpr in physical pixels,
                // the content keeps its 940×650 visual size, and after scaling it rasterizes at device pixels, consistent with real scaling.
                item.visible = true
            }
        }
        // Screen grab: main.cpp registers the QmlShot singleton (OrbbecShot module) in the screenshot build; writing the
        // capture key to it grabs one frame after the window is shown and then exits. Normal builds do not import this module.
        Timer {
            running: smoke.shotPath.length > 0
            interval: 1200
            repeat: false
            onTriggered: {
                shotWindow.show()
                shotWindow.raise()
                shotWindow.requestActivate()
                QmlShot.capture = smoke.shotPath
            }
        }
    }
}
