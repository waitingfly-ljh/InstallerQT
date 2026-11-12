// Install environment probing: target directory writability, free disk space, installed version.
// All calls are synchronous and read-only; the UI calls them once at startup and once per
// directory change.
#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>

struct InstalledInfo {
    bool installed = false;
    QString version;     // installed version (may be empty)
    QString installDir;  // installed directory
};

class Environment : public QObject
{
    Q_OBJECT
public:
    explicit Environment(QObject *parent = nullptr);

    // Directory writability: try creating and deleting a temporary file in the directory
    // (or its nearest existing ancestor). An empty string means usable; otherwise returns a
    // user-displayable reason (missing directory, not a directory, not writable).
    // Results are cached by "directory + ancestor modification time", so repeated binding
    // evaluation does not repeatedly write to disk.
    Q_INVOKABLE QString probeDirectory(const QString &path) const;

    // Remaining bytes on the volume containing the given path; returns -1 when unknown.
    Q_INVOKABLE qint64 freeBytes(const QString &path) const;

    // Normalization of install directory text (e.g. "C:/Program Files/OrbbecSlicer/" → "C:\Program Files\OrbbecSlicer"):
    // when text entered in the UI is used directly as the install location, installDirChanged
    // must compare normalized values.
    Q_INVOKABLE QString normalizeDirPath(const QString &path) const;

    // Default install directory: <ProgramFiles>\OrbbecSlicer
    Q_INVOKABLE QString defaultInstallDir() const;

    // The UI collects a "parent folder"; the actual install directory is <parent folder>\OrbbecSlicer.
    // If the last segment is already OrbbecSlicer (case-insensitive) it is not appended again;
    // repeated calls return the same result.
    Q_INVOKABLE QString installDirForParent(const QString &parent) const;

    // Default parent folder (parent of defaultInstallDir()), used to prefill the install options page.
    Q_INVOKABLE QString defaultInstallParent() const;

    // Final install directory → parent folder (for maintenance/refill).
    Q_INVOKABLE QString installParentForDir(const QString &installDir) const;

    // Version source: prefer the registry, fall back to maintenancetool.exe in the install directory.
    Q_INVOKABLE QVariantMap installedInfo() const;

    // Installed product version taken from the QIFW metadata written into the install
    // directory (<dir>/components.xml: the package <Version>, falling back to
    // <ApplicationVersion>). The registry "Version" value is only a cache written by the
    // shell after a successful install, so older installs must read the metadata itself.
    // Returns an empty string when the file is missing or unreadable.
    QString installedVersionFromDir(const QString &installDir) const;

    // The main executable name in the install directory varies by product (currently
    // ob-slicer.exe; legacy packages use OrbbecSlicer.exe).
    // Returns the first existing executable; returns an empty string when none exists.
    Q_INVOKABLE QString appExecutablePath(const QString &installDir) const;

    // Launch the installed main program; returns true on success.
    Q_INVOKABLE bool launch(const QString &program, const QStringList &args = {}) const;

    // Open the directory in the file manager.
    Q_INVOKABLE bool revealDirectory(const QString &path) const;

    Q_INVOKABLE QString logDirectory() const;

    // Product user data directory (the slicer's own Orbbec/OrbbecSlicer folder, not the installer's).
    // roaming=true -> %APPDATA% (presets, preferences, printer info, LAN access code),
    // roaming=false -> %LOCALAPPDATA% (cache and logs).
    // ORBBEC_SETUP_DATA_ROOT redirects both roots under a test directory (same hook as the uninstall cleanup).
    Q_INVOKABLE QString userDataDirectory(bool roaming) const;

    // Root of the pre-install snapshots: <installer local app data>/snapshots.
    // Kept outside the install directory so a snapshot survives the maintenance replace/rollback.
    Q_INVOKABLE QString snapshotDirectory() const;

    // Total size of the regular files under a directory (recursive, symlinks skipped); 0 when it does not exist.
    Q_INVOKABLE qint64 directoryBytes(const QString &path) const;

private:
    InstalledInfo readInstalled() const;
};
