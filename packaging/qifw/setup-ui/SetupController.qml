pragma ComponentBehavior: Bound
import QtQuick

// Installer UI state: page flow, install options, installed-version detection.
// The UI decides "which screen to show" only here; actual install/uninstall is executed by Host.engine.
QtObject {
    id: ctl

    // --- Page flow ---
    // welcome | license | options | maintenance | progress | complete | failure | dataScope | confirm | uninstalled
    // A fresh install walks welcome -> license -> options; an existing installation starts on maintenance.
    // "failure" is the progress screen with the error dialog on top (Main.qml), see viewIndex.
    property string view: "welcome"
    property bool uninstalling: false
    // License acceptance (fresh install only). Owned by the controller so "Back" from the options page
    // returns to a still-accepted license page.
    property bool licenseAccepted: false

    // Flow view used only for screenshots (--view): the engine is not running in screenshot mode, and ctl.view is positioned by App.qml according to --view.
    // The page stack follows flowView rather than ctl.view directly: the screenshot shell's pages are shown via
    // StackLayout's currentIndex, and each page's own visible flag is ignored by the layout (see App.qml applyShotState).
    // In normal launches setView() is never called, so it is always equal to view.
    property string flowView: view

    // currentIndex of the content-area StackLayout (shared by Main.qml and the screenshot shell).
    function setView(v) {
        view = v
        flowView = v
    }
    readonly property int viewIndex: {
        const v = flowView
        if (v === "welcome") return 0
        if (v === "license") return 1
        if (v === "options") return 2
        if (v === "maintenance") return 3
        // The failure screen is the progress screen with the error dialog on top (drawn by Main.qml).
        if (v === "progress" || v === "failure") return 4
        if (v === "complete") return 5
        if (v === "dataScope") return 6
        if (v === "confirm") return 7
        if (v === "uninstalled") return 8
        // Appended last so the indices above stay stable (the screenshot shell and main.cpp --view rely on them).
        if (v === "snapshot") return 9
        return 0
    }

    // --- Pre-install snapshot (maintenance flows) ---
    // The maintenance screens promise a recoverable snapshot; this state drives the snapshot page and the
    // rollback dialog. The engine owns the real files (<snapshotRoot>), the controller only mirrors the choice.
    property bool snapshotEnabled: true
    property string snapshotName: ""
    // Shopping list: the default name is timestamped so repeated maintenance runs never clash.
    function defaultSnapshotName() {
        const d = new Date()
        const p = (n) => (n < 10 ? "0" : "") + n
        return "snapshot" + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate())
               + "-" + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds())
    }
    readonly property var snapshots: Host.engine.snapshots
    readonly property bool hasSnapshots: snapshots.length > 0
    property bool rollbackOpen: false
    property string rollbackName: ""
    property string rollbackError: ""

    // Maintenance page -> snapshot page; a fresh install has nothing to back up and starts directly.
    function beginMaintenance() {
        if (!installed.installed) {
            beginInstall()
            return
        }
        snapshotEnabled = true
        snapshotName = defaultSnapshotName()
        Host.engine.refreshSnapshots()
        view = "snapshot"
    }
    function backFromSnapshot() { view = "maintenance" }

    function openRollback() {
        Host.engine.refreshSnapshots()
        rollbackError = ""
        rollbackName = snapshots.length > 0 ? snapshots[0].name : ""
        rollbackOpen = true
    }
    function confirmRollback() {
        const name = rollbackName.length > 0 ? rollbackName
                   : snapshots.length > 0 ? snapshots[0].name : ""
        if (name.length === 0) {
            rollbackError = qsTr("No snapshot available.")
            return
        }
        if (!Host.engine.restoreSnapshot(name)) {
            rollbackError = qsTr("Rolling back failed. The snapshot data is kept; please check the log and retry.")
            return
        }
        rollbackOpen = false
        refreshInstalled()
    }

    // --- Fresh-install navigation ---
    function nextFromWelcome() { view = "license" }
    function backFromLicense() { view = "welcome" }
    function nextFromLicense() { if (licenseAccepted) view = "options" }
    function backFromOptions() { view = "license" }

    // --- Install options ---
    property QtObject installOptions: QtObject {
        // The UI collects/displays the parent folder; installDir is the final install directory derived from it (engine input).
        property string installParentDir: ""
        property string installDir: ""
        property bool shortcutDesktop: true
        property bool assoc3mf: true
        property bool assocStl: false
        property bool launchAfterInstall: true
    }
    function resetOptions() {
        installOptions.installParentDir = Host.normalizeDirPath(Host.defaultInstallParent())
        installOptions.installDir = Host.installDirForParent(installOptions.installParentDir)
        installOptions.shortcutDesktop = true
        installOptions.assoc3mf = true
        installOptions.assocStl = false
        installOptions.launchAfterInstall = true
    }

    // --- Installed version ---
    property var installed: ({ "installed": false, "version": "", "installDir": "" })
    property string targetVersion: Host.payloadVersion
    property bool riskAcknowledged: false
    // Intent of this install flow: frozen from mode when "Install" is clicked.
    // After a successful install, installed becomes "installed with the same version" and mode becomes repair;
    // the complete page must not use the recomputed mode, otherwise a fresh install would show "Repair complete".
    property string runMode: "fresh"
    readonly property string mode: {
        if (!installed.installed) return "fresh"
        const a = compareVersions(targetVersion, installed.version)
        return a === 0 ? "repair" : a > 0 ? "upgrade" : "downgrade"
    }
    function compareVersions(a, b) {
        // "<numbers>[-<prerelease>]": only the part before '-' is numeric. A prerelease tag sorts BELOW its
        // release (0.4.0-beta.1 < 0.4.0); parsing "beta" as 0 and "1" as an extra segment did the opposite,
        // so re-installing 0.4.0-beta.1 over 0.4.0-beta.1 was classified as a downgrade.
        function parseVersion(v) {
            const s = String(v || "").trim()
            const dash = s.indexOf('-')
            return {
                nums: (dash >= 0 ? s.slice(0, dash) : s).split('.').map(x => parseInt(x, 10) || 0),
                pre: dash >= 0 ? s.slice(dash + 1) : ""
            }
        }
        function cmpNumber(x, y) { return x === y ? 0 : (x > y ? 1 : -1) }
        const pa = parseVersion(a), pb = parseVersion(b)
        for (let i = 0; i < Math.max(pa.nums.length, pb.nums.length); ++i) {
            const c = cmpNumber(pa.nums[i] || 0, pb.nums[i] || 0)
            if (c !== 0) return c
        }
        // Same numbers: a release outranks any prerelease of it.
        if (!pa.pre && !pb.pre) return 0
        if (!pa.pre) return 1
        if (!pb.pre) return -1
        // Semver prerelease order: numeric identifiers compare numerically and rank below alphanumeric ones.
        const ia = pa.pre.split('.'), ib = pb.pre.split('.')
        for (let i = 0; i < Math.max(ia.length, ib.length); ++i) {
            const xa = ia[i], xb = ib[i]
            if (xa === undefined) return -1
            if (xb === undefined) return 1
            const na = /^\d+$/.test(xa), nb = /^\d+$/.test(xb)
            if (na && nb) {
                const c = cmpNumber(parseInt(xa, 10), parseInt(xb, 10))
                if (c !== 0) return c
            } else if (na !== nb) {
                return na ? -1 : 1
            } else if (xa !== xb) {
                return xa > xb ? 1 : -1
            }
        }
        return 0
    }

    // --- Failure and uninstall ---
    property int failureCode: -1
    property string failureCodeText: ""
    property string failureMessage: ""
    // Whether the failed task was an uninstall (uninstalling is cleared before the dialog is shown).
    property bool failureWhileUninstalling: false
    // --- Failure dialog content (design: 配置迁移失败 popup) ---
    // The step list mirrors the phases the engine really reports (SetupEngine::phaseIndex), so the dialog
    // never claims progress the installer did not make:
    //   phaseIndex 0 = preparing, 1 = writing program files, 2 = finishing configuration.
    readonly property int failurePhase: Math.max(0, Math.min(2, Host.engine.phaseIndex))
    readonly property string failureTitle: {
        if (failureWhileUninstalling) return qsTr("Uninstall failed")
        if (runMode === "upgrade") return qsTr("Upgrade failed")
        if (runMode === "downgrade") return qsTr("Downgrade failed")
        if (runMode === "repair") return qsTr("Repair failed")
        return qsTr("Installation failed")
    }
    readonly property var failureSteps: {
        if (failureWhileUninstalling) {
            return [
                { "label": qsTr("Remove program files"), "state": "failed" },
                { "label": qsTr("Clean up installation records"), "state": "pending" }
            ]
        }
        const labels = [qsTr("Prepare the installation environment"),
                        qsTr("Write program files"),
                        qsTr("Finish configuration")]
        const p = failurePhase
        const out = []
        for (let i = 0; i < labels.length; ++i)
            out.push({ "label": labels[i], "state": i < p ? "done" : (i === p ? "failed" : "pending") })
        return out
    }
    property bool removeAllData: false
    property bool keepDataDir: false
    property bool cancelled: false
    // Progress wrap-up: show 100% and pause on success; on failure/cancel also pause briefly before switching pages.
    property bool finishing: false
    property int pendingCode: -1
    property string pendingSummary: ""
    readonly property int displayProgress: finishing ? 100 : Host.engine.progress

    // QtObject has no default property, so child objects must be attached to a concrete property.
    property Timer finishTimer: Timer {
        interval: 600
        repeat: false
        onTriggered: ctl.applyFinish()
    }

    // Launched from the system uninstall entry (--uninstall): skip maintenance detection and go straight to the uninstall flow.
    readonly property bool uninstallOnly: typeof uninstallMode !== "undefined" && uninstallMode === true
    readonly property string installDirOverride: (typeof installDirPath !== "undefined"
                                                  && installDirPath !== null) ? String(installDirPath) : ""

    function start() {
        refreshInstalled()
        if (uninstallOnly) {
            const dir = installDirOverride.length > 0 ? installDirOverride : installed.installDir
            installed = { "installed": true, "version": installed.version, "installDir": dir }
            uninstalling = true
            view = "dataScope"
            return
        }
        resetOptions()
        licenseAccepted = false
        view = installed.installed ? "maintenance" : "welcome"
    }

    function refreshInstalled() {
        Host.refreshInstalled()
        installed = Host.installed
    }

    function beginInstall() {
        runMode = mode
        cancelled = false
        if (installed.installed) {
            // Maintenance (repair/upgrade/downgrade) must stay in the original install directory: even if a custom directory name was used historically,
            // it must not be redirected to <parent>\OrbbecSlicer due to parent-folder semantics.
            installOptions.installDir = Host.normalizeDirPath(installOptions.installDir)
        } else {
            // Fresh install: compute the final directory from the parent folder ("D:", trailing slashes, etc. are normalized here).
            const parent = installOptions.installParentDir.length > 0
                         ? installOptions.installParentDir
                         : Host.defaultInstallParent()
            installOptions.installParentDir = Host.normalizeDirPath(parent)
            installOptions.installDir = Host.installDirForParent(installOptions.installParentDir)
        }
        if (installOptions.installDir.length === 0) {
            failureCode = 2
            failureCodeText = "2"
            failureMessage = qsTr("Install location is empty, please enter it again.")
            view = "failure"
            return
        }
        view = "progress"
        Host.engine.startInstall(installOptions.installDir, {
            "shortcutDesktop": installOptions.shortcutDesktop,
            "assoc3mf": installOptions.assoc3mf,
            "assocStl": installOptions.assocStl,
            "launchAfterInstall": installOptions.launchAfterInstall,
            // Only maintenance runs take a snapshot (a fresh install has nothing to back up).
            "snapshot": installed.installed && snapshotEnabled,
            "snapshotName": snapshotEnabled ? snapshotName : ""
        })
    }

    function onEngineFinished(code, summary) {
        pendingCode = code
        pendingSummary = summary
        finishing = code === 0
        finishTimer.interval = code === 0 ? 600 : 300
        finishTimer.restart()
    }

    function applyFinish() {
        finishing = false
        const code = pendingCode
        if (code === 0) {
            if (uninstalling) {
                uninstalling = false
                view = "uninstalled"
            } else {
                refreshInstalled()
                view = "complete"
            }
            return
        }
        failureWhileUninstalling = uninstalling
        uninstalling = false
        failureCode = code
        failureCodeText = code > 0 ? String(code) : ""
        failureMessage = pendingSummary
        // The snapshot is the recovery path, so say so right in the dialog that reports the failure.
        if (!failureWhileUninstalling && Host.engine.lastSnapshot.length > 0)
            failureMessage += "\n" + qsTr("The pre-install snapshot \"%1\" was kept; roll back to it from the maintenance screen.")
                                          .arg(Host.engine.lastSnapshot)
        view = "failure"
    }

    function onEngineCancelled() {
        // Cancel also pauses briefly to avoid the progress bar vanishing instantly.
        pendingCode = -1
        finishing = false
        finishTimer.stop()
        cancelTimer.start()
    }

    property Timer cancelTimer: Timer {
        interval: 300
        repeat: false
        onTriggered: {
            ctl.uninstalling = false
            ctl.cancelled = true
            ctl.view = ctl.installed.installed ? "maintenance" : "options"
        }
    }

    function retry() {
        view = installed.installed ? "maintenance" : "options"
    }

    function beginUninstall() {
        uninstalling = true
        view = "progress"
        Host.engine.startUninstall(installed.installDir, removeAllData, keepDataDir)
    }
}
