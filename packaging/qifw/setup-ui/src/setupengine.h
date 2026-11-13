// Install engine: runs QIFW silent install / uninstall as a child process and exposes
// a unified task lifecycle (start -> progress* -> finished) and log persistence to QML.
//
// Success/failure is judged only by exit code; stdout/stderr are used only for display and diagnostics.
#pragma once

#include <QObject>
#include <QProcess>
#include <QStringList>
#include <QVariantMap>

class QTimer;
class Environment;

class SetupEngine : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(int progress READ progress NOTIFY progressChanged)
    Q_PROPERTY(QString phase READ phase NOTIFY phaseChanged)
    // Numeric twin of `phase` (0 = preparing/verifying, 1 = writing program files, 2 = finishing
    // configuration). QML needs a language-independent value to mark the step list of the failure
    // dialog; comparing translated phase strings there would break as soon as the UI language changes.
    Q_PROPERTY(int phaseIndex READ phaseIndex NOTIFY phaseChanged)
    Q_PROPERTY(QString detail READ detail NOTIFY detailChanged)
    Q_PROPERTY(QString logPath READ logPath NOTIFY logPathChanged)
    // Pre-install snapshots (maintenance flows): [{ name, version, createdAt, bytes, path }], newest first.
    Q_PROPERTY(QVariantList snapshots READ snapshots NOTIFY snapshotsChanged)
    Q_PROPERTY(QString snapshotRoot READ snapshotRoot NOTIFY snapshotsChanged)
    // Name of the snapshot created for the current run (empty when the user chose not to create one).
    Q_PROPERTY(QString lastSnapshot READ lastSnapshot NOTIFY lastSnapshotChanged)

public:
    explicit SetupEngine(Environment *env, QObject *parent = nullptr);
    ~SetupEngine() override;

    bool busy() const { return m_busy; }
    int progress() const { return m_progress; }
    QString phase() const { return m_phase; }
    int phaseIndex() const { return m_phaseIndex; }
    QString detail() const { return m_detail; }
    QString logPath() const { return m_logPath; }
    QVariantList snapshots() const { return m_snapshots; }
    QString snapshotRoot() const;
    QString lastSnapshot() const { return m_lastSnapshot; }

    // Rescan <snapshotRoot> on disk (called at startup and after create/restore).
    Q_INVOKABLE void refreshSnapshots();
    // Restore the user data of a snapshot (program files are restored by the install itself).
    Q_INVOKABLE bool restoreSnapshot(const QString &name);
    // Snapshot name rules: starts with a letter, then letters/digits/._-, 1..65 characters.
    Q_INVOKABLE bool isValidSnapshotName(const QString &name) const;

    // When overwrite=false and the target directory already has content, the engine appends -x to force overwrite (QIFW refuses by default).
    Q_INVOKABLE void startInstall(const QString &targetDir, const QVariantMap &options);
    // Desktop shortcut: resolve the main program in the install directory and create <Desktop>\OrbbecSlicer.lnk.
    Q_INVOKABLE bool ensureDesktopShortcut(const QString &installDir);
    Q_INVOKABLE void startUninstall(const QString &installDir, bool removeAllData, bool keepDataDir);
    Q_INVOKABLE void cancel();

    // Installer payload path: in packaged mode SetupHost extracts it from its own trailing data area; in dev mode it comes from --payload.
    void setPayloadPath(const QString &path) { m_payloadPath = path; }
    // Self-contained uninstaller extracted by the Setup.exe launcher (deployed to the user directory after a successful install).
    void setUninstallerPath(const QString &path) { m_uninstallerSource = path; }
    void setLogPath(const QString &path);

signals:
    void busyChanged();
    void progressChanged();
    void phaseChanged();
    void detailChanged();
    void logPathChanged();
    void snapshotsChanged();
    void lastSnapshotChanged();
    void finished(int exitCode, const QString &summary);
    void cancelled();

private:
    void startProcess(const QString &program, const QStringList &args, const QString &phase);
    // Maintenance: take the pre-install snapshot (program dir + user data) before the old directory is replaced.
    enum class SnapshotResult { Ok, Failed, Cancelled };
    SnapshotResult createSnapshot(const QString &name, QString &error);
    void setLastSnapshot(const QString &name);
    // Runs the snapshot copy after the phase has been painted (called from startInstall).
    void prepareSnapshot();
    // startInstall continuation: prepare the install directory and launch QIFW (after the optional snapshot).
    void continueInstall();
    void onReadyRead();
    void onFinished(int exitCode, QProcess::ExitStatus status);
    void advancePhaseFromLine(const QString &line);
    void applyInstallOptions();
    bool createShortcut(const QString &lnkPath, const QString &target, const QString &workDir);
    bool createShellLink(const QString &lnkPath, const QString &target, const QString &args,
                         const QString &workDir);
    bool shellLinkTarget(const QString &lnkPath, QString &target) const;
    // On successful uninstall: delete the desktop shortcut created at install time (only if it points to this install's main program) and restore file associations.
    void revertInstallOptions();
    // After a successful install/maintenance: deploy the branded uninstaller and rewrite the system uninstall registration and Start menu shortcut.
    void installUninstaller();
    // Every Programs-and-Features key (HKCU/HKLM/WOW64) that belongs to installDir: DisplayName "OrbbecSlicer"
    // and either InstallLocation == installDir or an uninstall command pointing into installDir.
    QStringList uninstallKeysFor(const QString &installDir) const;
    // Delete one Programs-and-Features key by full path (HKEY_...\Software\Microsoft\...\Uninstall\{GUID}).
    void deleteUninstallKey(const QString &keyPath);
    // Startup self-check: recreate the Programs-and-Features entry when the recorded registration
    // is gone (external cleanup agents may drop it after a successful install).
    void repairUninstallRegistration();
    // After uninstall completes: delete the Start menu shortcut, the self-created uninstall registration, and the Uninstaller value.
    void removeUninstallerRegistration();
    void cleanupUserDataIfRequested();
    // After a successful uninstall (engine exit code 0), delete the install directory: QIFW's pr cannot delete the running
    // maintenancetool.exe, so after the child process exits, clean up the residue here and remove the directory itself.
    // Returns true if the directory no longer exists; on false, residual gives the list of leftover relative paths.
    bool cleanupInstallDirAfterUninstall(QString &residual);
    void appendLog(const QString &line);
    QString makeLogPath() const;
    void setProgress(int value);
    // Maintenance (repair/upgrade/downgrade): QIFW refuses to overwrite an installed directory. First rename the old directory to a backup,
    // restore it if install fails/cancels, and delete the backup on success.
    bool beginReplaceExisting();
    void restoreBackup();
    void dropBackup();
    void cleanupAfterCancel();

    Environment *m_env = nullptr;
    QProcess *m_proc = nullptr;
    QTimer *m_ticker = nullptr;
    QString m_payloadPath;
    QString m_uninstallerSource;
    QString m_uninstallerDeployed;
    QString m_selfUninstallKey;   // Self-created uninstall registration key (QIFW's key is deleted by pr itself)
    QString m_cacheDir;
    QString m_installDir;
    QString m_logPath;
    QString m_phase;
    int m_phaseIndex = 0;     // Numeric twin of m_phase, exposed to QML (see the Q_PROPERTY comment)
    QString m_detail;
    QString m_pendingLine;
    QString m_backupDir;      // Temporary backup of the old install directory during maintenance (empty = not an overwrite install)
    int m_progress = 0;
    bool m_busy = false;
    bool m_cancelRequested = false;
    bool m_uninstallMode = false;
    bool m_targetExisted = false;   // Whether the target directory existed before install (decides whether the whole directory can be deleted on cancel)
    bool m_removeAllData = false;
    bool m_keepDataDir = false;
    // Install options: the QIFW package itself does not handle them; applyInstallOptions() applies them after a successful install.
    bool m_shortcutDesktop = false;
    bool m_assoc3mf = false;
    bool m_assocStl = false;
    // "Launch after install": the Complete page's "Launch now" default action reads it (Main.qml); here we only store the choice.
    bool m_launchAfterInstall = false;
    // Pre-install snapshot: the name the UI asked for, and the one that was actually created.
    bool m_snapshotRequested = false;
    QString m_snapshotName;
    QString m_lastSnapshot;
    QVariantList m_snapshots;
    // Progress the install process starts from (a snapshot run leaves it at 8%).
    int m_startProgress = 0;
};
