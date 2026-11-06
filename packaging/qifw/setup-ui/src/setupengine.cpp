#include "setupengine.h"

#include "environment.h"

#include <QDateTime>
#include <QCoreApplication>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QProcessEnvironment>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QUuid>
#include <QTime>
#include <QThread>
#include <QTimer>
#include <QVariantMap>

#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>

#include <algorithm>
#include <climits>
#include "msopen.h"

namespace {
// File association ProgId reuses the naming from the original NSIS scheme (BrandedMaintenance.nsh) so upgrade/uninstall can match it.
constexpr QLatin1String kProgId3mf("OrbbecSlicer.3mf");
constexpr QLatin1String kProgIdStl("OrbbecSlicer.stl");

QString classesKey(const QString &sub)
{
    return QStringLiteral("HKEY_CURRENT_USER\\Software\\Classes\\") + sub;
}

QString typeKey(const QString &ext)
{
    return ext == QLatin1String(".3mf") ? kProgId3mf : kProgIdStl;
}

// Record .3mf as "project" and .stl as "model", consistent with the product's wording.
QString typeName(const QString &ext)
{
    return ext == QLatin1String(".3mf") ? QObject::tr("OrbbecSlicer project")
                                        : QObject::tr("OrbbecSlicer model");
}

// Source of the association icon: prefer the application icon registered by the system for the exe (with full path and index),
// fall back to the exe's own icon. The return value is written directly into ProgId\DefaultIcon.
QString iconLocation(const QString &exe)
{
    const QString nativeExe = QDir::toNativeSeparators(exe);
    QSettings appIcons(QStringLiteral("HKEY_CLASSES_ROOT\\Applications\\") + nativeExe + QStringLiteral("\\DefaultIcon"),
                       QSettings::NativeFormat);
    const QString registered = appIcons.value(QStringLiteral(".")).toString();
    if (!registered.isEmpty())
        return registered;
    return nativeExe + QStringLiteral(",0");
}

// Write (enabled) or revert (!enabled) an association for one extension based on the choice.
// Consistent with the NSIS scheme: only touch HKCU\Software\Classes, do not change Windows' own UserChoice;
// before associating, record the type's original default program under Software\Orbbec\OrbbecSlicer\Assoc, and restore it on revert.
void setAssociation(QSettings &record, const QString &ext, bool enabled, const QString &exe)
{
    const QString progId = typeKey(ext);
    QSettings type(classesKey(ext), QSettings::NativeFormat);
    const QString savedKey = QStringLiteral("previous") + ext;

    if (enabled) {
        const QString current = type.value(QStringLiteral(".")).toString();
        if (current != progId && !record.contains(savedKey))
            record.setValue(savedKey, current);

        QSettings prog(classesKey(progId), QSettings::NativeFormat);
        prog.setValue(QStringLiteral("."), typeName(ext));
        prog.setValue(QStringLiteral("DefaultIcon/."), iconLocation(exe));
        prog.setValue(QStringLiteral("shell/open/command/."),
                      QStringLiteral("\"%1\" \"%2\"").arg(QDir::toNativeSeparators(exe), QStringLiteral("%1")));
        prog.sync();
        type.setValue(QStringLiteral("."), progId);
        type.setValue(QStringLiteral("OpenWithProgids/") + progId, QString());
        type.sync();
    } else {
        // Revert: restore the recorded previous program, then drop our own ProgId.
        // The record can be missing when the association was already ours before this install
        // (for example left over from an interrupted run, or a failed uninstall); in that case the
        // extension still has to be cleared, otherwise the stale .3mf/ProgId survives every later
        // uninstall and no run can ever get back to a clean state.
        const QString current = type.value(QStringLiteral(".")).toString();
        const bool hasRecord = record.contains(savedKey);
        if (hasRecord || current == progId) {
            if (hasRecord) {
                const QString previous = record.value(savedKey).toString();
                if (previous.isEmpty())
                    type.remove(QStringLiteral("."));
                else
                    type.setValue(QStringLiteral("."), previous);
            } else {
                type.remove(QStringLiteral("."));
            }
            type.remove(QStringLiteral("OpenWithProgids/") + progId);
            type.sync();
            record.remove(savedKey);
            QSettings(classesKey(progId), QSettings::NativeFormat).clear();
        }
    }
    record.sync();
}

// Complete arguments for QIFW silent install: unattended, no license/message dialogs, both cache and target are specifiable.
QStringList qifwInstallArgs(const QString &targetDir, const QString &cacheDir)
{
    return {
        QStringLiteral("--platform"), QStringLiteral("minimal"),
        QStringLiteral("in"), QStringLiteral("-c"),
        QStringLiteral("--confirm-command"),
        QStringLiteral("--accept-licenses"),
        QStringLiteral("--accept-messages"),
        QStringLiteral("--cp"), cacheDir,
        QStringLiteral("-t"), targetDir,
    };
}
} // namespace

SetupEngine::SetupEngine(Environment *env, QObject *parent) : QObject(parent), m_env(env)
{
    m_ticker = new QTimer(this);
    m_ticker->setInterval(250);
    connect(m_ticker, &QTimer::timeout, this, [this] {
        // When no concrete percentage is available, advance slowly by phase weight, but never reach 99% before the engine finishes.
        if (!m_busy || m_progress >= 99)
            return;
        if (m_phase == tr("Writing program files"))
            setProgress(m_progress + 1);
        else if (m_progress < 5)
            setProgress(std::min(m_progress + 1, 5));
        else if (m_progress < 96)
            setProgress(m_progress + (m_progress < 60 ? 2 : 1));
    });
    m_logPath = makeLogPath();
}

SetupEngine::~SetupEngine()
{
    if (m_proc) {
        m_proc->disconnect(this);
        if (m_proc->state() != QProcess::NotRunning) {
            m_proc->kill();
            m_proc->waitForFinished(3000);
        }
        m_proc->deleteLater();
    }
    // Restore the old program directory when the process is force-terminated (app exit).
    if (!m_backupDir.isEmpty())
        restoreBackup();
}

void SetupEngine::setLogPath(const QString &path)
{
    if (path.isEmpty() || path == m_logPath)
        return;
    m_logPath = path;
    emit logPathChanged();
}

QString SetupEngine::makeLogPath() const
{
    const QString dir = m_env ? m_env->logDirectory()
                              : QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
                                    + QStringLiteral("/logs");
    QDir().mkpath(dir);
    return QDir::toNativeSeparators(
        QDir(dir).filePath(QStringLiteral("setup-%1.log")
                               .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss")))));
}

void SetupEngine::appendLog(const QString &line)
{
    QFile f(m_logPath);
    if (!f.open(QIODevice::Append | QIODevice::Text))
        return;
    f.write(QStringLiteral("[%1] %2\n")
                .arg(QTime::currentTime().toString(QStringLiteral("HH:mm:ss")), line)
                .toUtf8());
}

void SetupEngine::startProcess(const QString &program, const QStringList &args, const QString &phase)
{
    if (m_busy) {
        emit finished(3, tr("A task is already in progress"));
        return;
    }
    if (!QFileInfo::exists(program)) {
        // Log stays English for support/diagnostics; the UI summary is translated.
        appendLog(QStringLiteral("Cannot find install engine: %1").arg(QDir::toNativeSeparators(program)));
        restoreBackup();
        emit finished(2, tr("Cannot find install engine: %1").arg(QDir::toNativeSeparators(program)));
        return;
    }

    m_busy = true;
    m_cancelRequested = false;
    m_pendingLine.clear();
    setProgress(0);
    m_phase = phase;
    emit phaseChanged();
    m_detail = tr("Preparing components");
    emit detailChanged();
    emit busyChanged();

    appendLog(QStringLiteral("Engine: %1").arg(QDir::toNativeSeparators(program)));
    appendLog(QStringLiteral("Arguments: %1").arg(args.join(QLatin1Char(' '))));

    m_proc = new QProcess(this);
    m_proc->setProcessChannelMode(QProcess::MergedChannels);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    // The child process is also started with the minimal platform: never show the user any of QIFW's own windows.
    env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("minimal"));
    m_proc->setProcessEnvironment(env);
    connect(m_proc, &QProcess::readyReadStandardOutput, this, &SetupEngine::onReadyRead);
    connect(m_proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            &SetupEngine::onFinished);
    connect(m_proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError err) {
        if (err != QProcess::FailedToStart)
            return;
        const QString msg = QStringLiteral("Engine failed to start: %1").arg(m_proc ? m_proc->errorString() : QString());
        appendLog(msg);
        m_ticker->stop();
        m_busy = false;
        emit busyChanged();
        restoreBackup();
        emit finished(2, tr("Engine failed to start: %1").arg(m_proc ? m_proc->errorString() : QString()));
    });
    m_proc->start(program, args);
    m_ticker->start();
}

bool SetupEngine::beginReplaceExisting()
{
    // Maintenance (repair/upgrade/downgrade): QIFW's installerbase fails directly with
    // TargetDirectoryInUse when "the directory already has an install", so first rename the old program directory to a backup, then write the new install.
    // On failure/cancel, rename the backup back so the original version can still launch.
    dropBackup();
    const QString mt = QDir(m_installDir).filePath(QStringLiteral("maintenancetool.exe"));
    if (!QFileInfo::exists(mt))
        return true;
    m_backupDir = m_installDir + QStringLiteral(".orbbec-backup-")
                  + QString::number(QCoreApplication::applicationPid());
    QDir parent(QFileInfo(m_installDir).absolutePath());
    const QString oldName = QFileInfo(m_installDir).fileName();
    const QString newName = QFileInfo(m_backupDir).fileName();
    if (!parent.rename(oldName, newName)) {
        appendLog(QStringLiteral("Failed to back up old install directory: %1 → %2").arg(QDir::toNativeSeparators(m_installDir),
                                                              QDir::toNativeSeparators(m_backupDir)));
        m_backupDir.clear();
        return false;
    }
    appendLog(QStringLiteral("Maintenance: old program directory backed up to %1").arg(QDir::toNativeSeparators(m_backupDir)));
    return true;
}

void SetupEngine::restoreBackup()
{
    if (m_backupDir.isEmpty())
        return;
    QDir(m_installDir).removeRecursively();
    QDir parent(QFileInfo(m_installDir).absolutePath());
    const QString oldName = QFileInfo(m_backupDir).fileName();
    const QString newName = QFileInfo(m_installDir).fileName();
    const bool ok = parent.rename(oldName, newName);
    appendLog(ok ? QStringLiteral("Maintenance failed: original program directory restored")
                 : QStringLiteral("Maintenance failed: failed to restore original program directory, backup still at %1")
                       .arg(QDir::toNativeSeparators(m_backupDir)));
    m_backupDir.clear();
}

void SetupEngine::dropBackup()
{
    if (m_backupDir.isEmpty())
        return;
    QDir(m_backupDir).removeRecursively();
    appendLog(QStringLiteral("Maintenance complete: deleted old program directory backup %1").arg(QDir::toNativeSeparators(m_backupDir)));
    m_backupDir.clear();
}

void SetupEngine::cleanupAfterCancel()
{
    // Clean up this run's writes after cancel:
    //  - Directory did not exist before install: delete the whole directory;
    //  - Directory already existed (including an installed version): already restored by restoreBackup, no action needed;
    //  - Directory exists but is not an install directory: QIFW rolls back the partial files this run may have written; do not touch it here.
    if (!m_targetExisted) {
        const bool ok = QDir(m_installDir).removeRecursively();
        appendLog(ok ? QStringLiteral("Cancelled: deleted install directory created this run %1").arg(QDir::toNativeSeparators(m_installDir))
                     : QStringLiteral("Cancelled: failed to delete install directory, please clean up manually %1").arg(QDir::toNativeSeparators(m_installDir)));
    } else {
        appendLog(QStringLiteral("Cancelled: target directory existed before install, kept undeleted"));
    }
}

void SetupEngine::startInstall(const QString &targetDir, const QVariantMap &options)
{
    if (m_payloadPath.isEmpty() || !QFileInfo::exists(m_payloadPath)) {
        appendLog(QStringLiteral("Installer payload does not exist: %1").arg(QDir::toNativeSeparators(m_payloadPath)));
        emit finished(2, tr("Installer payload does not exist: %1").arg(QDir::toNativeSeparators(m_payloadPath)));
        return;
    }
    m_uninstallMode = false;
    m_installDir = QDir::toNativeSeparators(targetDir);
    m_targetExisted = QFileInfo::exists(m_installDir);
    m_cacheDir = QDir(QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation))
                     .filePath(QStringLiteral("installer-cache"));
    QDir().mkpath(m_cacheDir);

    if (!beginReplaceExisting()) {
        appendLog(QStringLiteral("Cannot prepare maintenance install directory: %1").arg(m_installDir));
        emit finished(4, tr("Cannot prepare maintenance install directory: %1").arg(m_installDir));
        return;
    }
    QStringList args = qifwInstallArgs(m_installDir, m_cacheDir);
    // Note: QIFW 4.11's installerbase has no overwrite switch (-x is treated as Unknown option);
    // overwrite/repair is done by the maintenance entry and -t pointing to the same directory, so no extra arguments are appended here.
    m_shortcutDesktop = options.value(QStringLiteral("shortcutDesktop")).toBool();
    m_assoc3mf = options.value(QStringLiteral("assoc3mf")).toBool();
    m_assocStl = options.value(QStringLiteral("assocStl")).toBool();
    m_launchAfterInstall = options.value(QStringLiteral("launchAfterInstall")).toBool();
    appendLog(QStringLiteral("Install options: shortcut=%1 .3mf=%2 .stl=%3 launch after install=%4")
                  .arg(m_shortcutDesktop).arg(m_assoc3mf).arg(m_assocStl)
                  .arg(m_launchAfterInstall));
    startProcess(m_payloadPath, args, tr("Verifying installer payload"));
}

void SetupEngine::startUninstall(const QString &installDir, bool removeAllData, bool keepDataDir)
{
    m_uninstallMode = true;
    m_removeAllData = removeAllData;
    m_keepDataDir = keepDataDir;
    m_installDir = QDir::toNativeSeparators(installDir);
    m_cacheDir = QDir(QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation))
                     .filePath(QStringLiteral("installer-cache"));
    QDir().mkpath(m_cacheDir);

    const QString mt = QDir(m_installDir).filePath(QStringLiteral("maintenancetool.exe"));
    if (!QFileInfo::exists(mt)) {
        // Install directory was manually deleted: no maintenancetool needed, clean the entries and user data directly.
        appendLog(QStringLiteral("maintenancetool.exe not found in install directory, skipping program file removal"));
        m_uninstallMode = true;
        cleanupUserDataIfRequested();
        // If the directory is empty, delete it too; if it still has user files, keep it.
        if (QFileInfo::exists(m_installDir))
            QDir().rmdir(m_installDir);
        emit finished(0, tr("Program files no longer exist, uninstall registration and user data cleaned"));
        return;
    }
    m_shortcutDesktop = false;
    m_assoc3mf = false;
    m_assocStl = false;
    m_launchAfterInstall = false;
    startProcess(mt,
                 {
                     QStringLiteral("--platform"), QStringLiteral("minimal"),
                     QStringLiteral("pr"), QStringLiteral("-c"),
                     QStringLiteral("--confirm-command"),
                     QStringLiteral("--accept-licenses"),
                     QStringLiteral("--accept-messages"),
                     QStringLiteral("--cp"), m_cacheDir,
                 },
                 tr("Removing program files"));
}

void SetupEngine::cancel()
{
    if (!m_busy || !m_proc)
        return;
    m_cancelRequested = true;
    m_detail = tr("Cancelling…");
    emit detailChanged();
    appendLog(QStringLiteral("User requested cancel"));
    m_proc->terminate();
    // Force kill if not exited within 3 seconds: QIFW's handling of SIGTERM is not guaranteed.
    QTimer::singleShot(3000, this, [this] {
        if (m_proc && m_proc->state() != QProcess::NotRunning)
            m_proc->kill();
    });
}

void SetupEngine::onReadyRead()
{
    if (!m_proc)
        return;
    QByteArray chunk = m_proc->readAllStandardOutput();
    m_pendingLine += QString::fromLocal8Bit(chunk);
    while (true) {
        const int idx = m_pendingLine.indexOf(QLatin1Char('\n'));
        if (idx < 0)
            break;
        QString line = m_pendingLine.left(idx).trimmed();
        m_pendingLine.remove(0, idx + 1);
        if (line.isEmpty())
            continue;
        appendLog(line);
        advancePhaseFromLine(line);
    }
}

void SetupEngine::advancePhaseFromLine(const QString &line)
{
    // Display only: QIFW's progress output format is unstable; group by keyword into three phases.
    QString next = m_phase;
    if (!m_uninstallMode) {
        if (line.contains(QStringLiteral("extract"), Qt::CaseInsensitive)
            || line.contains(QStringLiteral("Extracting"), Qt::CaseInsensitive)) {
            next = tr("Writing program files");
        } else if (line.contains(QStringLiteral("branding"), Qt::CaseInsensitive)
                   || line.contains(QStringLiteral("shortcut"), Qt::CaseInsensitive)) {
            next = tr("Finishing configuration");
        }
    }
    if (next != m_phase) {
        m_phase = next;
        emit phaseChanged();
        appendLog(QStringLiteral("Phase: %1").arg(m_phase));
        if (!m_uninstallMode) {
            setProgress(m_phase == tr("Writing program files") ? 8 : m_progress);
        }
    }
    m_detail = line.left(120);
    emit detailChanged();
}

void SetupEngine::setProgress(int value)
{
    value = std::clamp(value, 0, 100);
    if (value == m_progress)
        return;
    m_progress = value;
    emit progressChanged();
}

void SetupEngine::onFinished(int exitCode, QProcess::ExitStatus status)
{
    m_ticker->stop();
    if (m_proc) {
        // Finalize: also read the last line in the buffer that has no trailing newline.
        m_pendingLine += QString::fromLocal8Bit(m_proc->readAllStandardOutput());
        if (!m_pendingLine.trimmed().isEmpty())
            appendLog(m_pendingLine.trimmed());
        m_pendingLine.clear();
    }
    const bool crashed = (status == QProcess::CrashExit);
    appendLog(QStringLiteral("Engine exited: code=%1 status=%2").arg(exitCode).arg(crashed ? "crash" : "normal"));

    m_busy = false;
    emit busyChanged();

    if (m_cancelRequested) {
        restoreBackup();
        if (!m_uninstallMode)
            cleanupAfterCancel();
        emit cancelled();
        return;
    }

    if (crashed || exitCode != 0) {
        restoreBackup();
        emit finished(crashed ? -1 : exitCode,
                      tr("Install engine exited with %1").arg(crashed ? tr("abnormal status") : QString::number(exitCode)));
        return;
    }

    if (m_uninstallMode) {
        cleanupUserDataIfRequested();
        // QIFW's pr cannot delete the running maintenancetool.exe; delete it here after the child process exits.
        // The directory must disappear entirely; if it cannot be deleted, fail, to avoid "looks cleanly uninstalled but actually leaves 36 MB of metadata".
        QString residual;
        if (!cleanupInstallDirAfterUninstall(residual)) {
            setProgress(100);
            emit finished(5, tr("Program files deleted, but install directory still has residue: %1").arg(residual));
            return;
        }
    } else {
        // Maintenance succeeded: the new program directory is in place, the old backup can be deleted.
        dropBackup();
        applyInstallOptions();
        installUninstaller();
    }
    setProgress(100);
    emit finished(0, m_uninstallMode ? tr("Uninstall complete") : tr("Install complete"));
}

void SetupEngine::applyInstallOptions()
{
    // The QIFW package has no component script and does not read the shell's options, so shortcuts and file associations are added here:
    //   - Desktop shortcut: %USERPROFILE%\Desktop\OrbbecSlicer.lnk (uninstall uses QIFW's clean uninstall,
    //     this missed item will not be cleaned before maintenancetool removes the directory);
    //   - File associations: HKCU\Software\Classes, only changes the current user, no admin rights needed.
    // Any failure is only logged; a successful install is not judged as failed.
    // The main program name varies by product: currently ob-slicer.exe in staging (historical packages use OrbbecSlicer.exe).
    const QString exe = m_env ? m_env->appExecutablePath(m_installDir) : QString();
    if (exe.isEmpty()) {
        appendLog(QStringLiteral("Main program not found in install directory (ob-slicer.exe / OrbbecSlicer.exe), skipping shortcut and file associations"));
        return;
    }
    const QString exeNative = QDir::toNativeSeparators(exe);

    if (m_shortcutDesktop)
        ensureDesktopShortcut(m_installDir);

    {
        const QString programs = QStandardPaths::writableLocation(QStandardPaths::ApplicationsLocation);
        const QString smDir = QDir(programs).filePath(QStringLiteral("OrbbecSlicer"));
        const QString smLnk = QDir(smDir).filePath(QStringLiteral("OrbbecSlicer.lnk"));
        const bool ok = createShellLink(smLnk, exe, QString(), QDir::toNativeSeparators(m_installDir));
        appendLog(ok ? QStringLiteral("Created Start menu shortcut: %1").arg(QDir::toNativeSeparators(smLnk))
                     : QStringLiteral("Failed to create Start menu shortcut: %1").arg(QDir::toNativeSeparators(smLnk)));
    }

    QSettings record(QStringLiteral("HKEY_CURRENT_USER\\Software\\Orbbec\\OrbbecSlicer\\Assoc"),
                     QSettings::NativeFormat);
    setAssociation(record, QStringLiteral(".3mf"), m_assoc3mf, exe);
    setAssociation(record, QStringLiteral(".stl"), m_assocStl, exe);
    appendLog(QStringLiteral("File associations: .3mf=%1 .stl=%2").arg(m_assoc3mf).arg(m_assocStl));
}

bool SetupEngine::ensureDesktopShortcut(const QString &installDir)
{
    const QString exe = m_env ? m_env->appExecutablePath(installDir) : QString();
    if (exe.isEmpty()) {
        appendLog(QStringLiteral("Cannot create desktop shortcut: no main program in install directory (%1)")
                      .arg(QDir::toNativeSeparators(installDir)));
        return false;
    }
    const QString desktop = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
    if (desktop.isEmpty()) {
        appendLog(QStringLiteral("Cannot create desktop shortcut: cannot get desktop directory"));
        return false;
    }
    const QString lnk = QDir(desktop).filePath(QStringLiteral("OrbbecSlicer.lnk"));
    const bool ok = createShellLink(lnk, exe, QString(), QDir::toNativeSeparators(installDir));
    if (ok) {
        QSettings marker(QStringLiteral("HKEY_CURRENT_USER\\Software\\Orbbec\\OrbbecSlicer"),
                         QSettings::NativeFormat);
        marker.setValue(QStringLiteral("DesktopShortcut"), QDir::toNativeSeparators(lnk));
        marker.sync();
    }
    appendLog(ok ? QStringLiteral("Created desktop shortcut: %1 → %2")
                       .arg(QDir::toNativeSeparators(lnk), QDir::toNativeSeparators(exe))
                 : QStringLiteral("Failed to create desktop shortcut: %1").arg(QDir::toNativeSeparators(lnk)));
    return ok;
}

bool SetupEngine::createShellLink(const QString &lnkPath, const QString &target, const QString &args,
                                  const QString &workDir)
{
#ifdef Q_OS_WIN
    const HRESULT hrInit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IShellLinkW *link = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_IShellLinkW,
                                  reinterpret_cast<void **>(&link));
    bool ok = false;
    if (SUCCEEDED(hr) && link) {
        const QString nativeTarget = QDir::toNativeSeparators(target);
        const QString nativeWork = QDir::toNativeSeparators(workDir);
        const QString nativeLnk = QDir::toNativeSeparators(lnkPath);
        link->SetPath(reinterpret_cast<LPCWSTR>(nativeTarget.utf16()));
        if (!args.isEmpty())
            link->SetArguments(reinterpret_cast<LPCWSTR>(args.utf16()));
        if (!workDir.isEmpty())
            link->SetWorkingDirectory(reinterpret_cast<LPCWSTR>(nativeWork.utf16()));
        IPersistFile *file = nullptr;
        if (SUCCEEDED(link->QueryInterface(IID_IPersistFile, reinterpret_cast<void **>(&file))) && file) {
            QDir().mkpath(QFileInfo(lnkPath).absolutePath());
            ok = SUCCEEDED(file->Save(reinterpret_cast<LPCOLESTR>(nativeLnk.utf16()), TRUE));
            file->Release();
        }
        link->Release();
    }
    if (SUCCEEDED(hrInit))
        CoUninitialize();
    return ok;
#else
    Q_UNUSED(lnkPath)
    Q_UNUSED(target)
    Q_UNUSED(args)
    Q_UNUSED(workDir)
    return false;
#endif
}

bool SetupEngine::createShortcut(const QString &lnkPath, const QString &target, const QString &workDir)
{
    return createShellLink(lnkPath, target, QString(), workDir);
}

bool SetupEngine::shellLinkTarget(const QString &lnkPath, QString &target) const
{
#ifdef Q_OS_WIN
    const HRESULT hrInit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IShellLinkW *link = nullptr;
    bool ok = false;
    if (SUCCEEDED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_IShellLinkW,
                                   reinterpret_cast<void **>(&link))) && link) {
        IPersistFile *file = nullptr;
        const QString native = QDir::toNativeSeparators(lnkPath);
        if (SUCCEEDED(link->QueryInterface(IID_IPersistFile, reinterpret_cast<void **>(&file))) && file) {
            if (SUCCEEDED(file->Load(reinterpret_cast<LPCOLESTR>(native.utf16()), STGM_READ))) {
                wchar_t buf[MAX_PATH] = {};
                if (SUCCEEDED(link->GetPath(buf, MAX_PATH, nullptr, 0)) && buf[0]) {
                    target = QString::fromWCharArray(buf);
                    ok = true;
                }
            }
            file->Release();
        }
        link->Release();
    }
    if (SUCCEEDED(hrInit))
        CoUninitialize();
    return ok;
#else
    Q_UNUSED(lnkPath)
    Q_UNUSED(target)
    return false;
#endif
}

void SetupEngine::revertInstallOptions()
{
    // 1) Desktop shortcut: prefer the path recorded at install time (it can only have been created by us); for old installs with no record,
    //    judge by "target is in this install directory and is a known main program".
    const QString desktop = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
    QSettings marker(QStringLiteral("HKEY_CURRENT_USER\\Software\\Orbbec\\OrbbecSlicer"),
                     QSettings::NativeFormat);
    const QString recorded = marker.value(QStringLiteral("DesktopShortcut")).toString();
    const QString lnk = recorded.isEmpty()
                            ? QDir(desktop).filePath(QStringLiteral("OrbbecSlicer.lnk"))
                            : recorded;
    bool shouldRemove = false;
    if (!recorded.isEmpty()) {
        shouldRemove = true;
    } else if (QFileInfo::exists(lnk)) {
        QString target;
        if (shellLinkTarget(lnk, target)) {
            const QString t = QDir::cleanPath(QDir::fromNativeSeparators(target));
            const QString d = QDir::cleanPath(QDir::fromNativeSeparators(m_installDir));
            const QString name = QFileInfo(t).fileName();
            const bool sameDir = t.startsWith(d + QLatin1Char('/'), Qt::CaseInsensitive);
            const bool known = name.compare(QStringLiteral("ob-slicer.exe"), Qt::CaseInsensitive) == 0
                               || name.compare(QStringLiteral("OrbbecSlicer.exe"), Qt::CaseInsensitive) == 0;
            shouldRemove = sameDir && known;
        }
    }
    if (!recorded.isEmpty() && !QFileInfo::exists(lnk)) {
        // Under some sandboxes/filter drivers stat fails but the file is still there: fall back to directory listing.
        const QStringList entries = QDir(desktop).entryList(QStringList() << QStringLiteral("OrbbecSlicer.lnk"),
                                                            QDir::Files | QDir::Hidden);
        shouldRemove = shouldRemove || !entries.isEmpty();
    }
    if (shouldRemove && QFile::remove(lnk))
        appendLog(QStringLiteral("Deleted desktop shortcut: %1").arg(QDir::toNativeSeparators(lnk)));
    else
        appendLog(QStringLiteral("Kept desktop shortcut (target is not this install or deletion failed): %1")
                      .arg(QDir::toNativeSeparators(lnk)));
    marker.remove(QStringLiteral("DesktopShortcut"));
    marker.sync();

    // 2) File associations: restore using the original values recorded at install time, then clear the records.
    // Always call both: setAssociation also removes stale OrbbecSlicer.* mappings that were left
    // behind without a recorded previous value, so an empty record must not skip the cleanup.
    const QString exe = m_env ? m_env->appExecutablePath(m_installDir) : QString();
    QSettings record(QStringLiteral("HKEY_CURRENT_USER\\Software\\Orbbec\\OrbbecSlicer\\Assoc"),
                     QSettings::NativeFormat);
    setAssociation(record, QStringLiteral(".3mf"), false, exe);
    setAssociation(record, QStringLiteral(".stl"), false, exe);
    record.remove(QString());
    record.sync();
    appendLog(QStringLiteral("Restored .3mf/.stl file associations"));
}

void SetupEngine::installUninstaller()
{
    // After a successful install/maintenance: deploy the self-contained uninstaller to the user directory and point the system uninstall entry to it.
    // QIFW's maintenancetool.exe stays in the install directory for maintenance/update but is no longer a user-visible entry.
    const QString installDir = QDir::toNativeSeparators(m_installDir);
    if (m_uninstallerSource.isEmpty() || !QFileInfo::exists(m_uninstallerSource)) {
        appendLog(QStringLiteral("No uninstaller source file provided, skipping uninstall entry deployment"));
        return;
    }
    // Test hook: the packaging loop redirects the data root under out/, to avoid touching real local user data.
    const QString dataRoot = qEnvironmentVariable("ORBBEC_SETUP_DATA_ROOT");
    const QString local = dataRoot.isEmpty() ? qEnvironmentVariable("LOCALAPPDATA")
                                             : QDir(dataRoot).filePath(QStringLiteral("Local"));
    if (local.isEmpty()) {
        appendLog(QStringLiteral("LOCALAPPDATA is empty, skipping uninstall entry deployment"));
        return;
    }
    const QString dir = QDir(local).filePath(QStringLiteral("Orbbec/OrbbecSlicer/uninstaller"));
    QDir().mkpath(dir);
    const QString dest = QDir::toNativeSeparators(
        QDir(dir).filePath(QStringLiteral("OrbbecSlicerUninstaller.exe")));
    if (QFileInfo::exists(dest) && !QFile::remove(dest)) {
        appendLog(QStringLiteral("Cannot overwrite old uninstaller: %1").arg(QDir::toNativeSeparators(dest)));
        return;
    }
    if (!QFile::copy(m_uninstallerSource, dest)) {
        appendLog(QStringLiteral("Failed to copy uninstaller: %1 → %2").arg(QDir::toNativeSeparators(m_uninstallerSource),
                                                          QDir::toNativeSeparators(dest)));
        return;
    }
    m_uninstallerDeployed = QDir::toNativeSeparators(dest);

    const QString uninstallString = QStringLiteral("\"%1\" --uninstall --install-dir \"%2\"")
                                        .arg(dest, installDir);
    const QString quietString = uninstallString + QStringLiteral(" --silent");

    // Find the QIFW-generated uninstall registration (matched by DisplayName + InstallLocation).
    QString keyPath;
    const QStringList roots = {
        QStringLiteral("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall"),
        QStringLiteral("HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall"),
        QStringLiteral("HKEY_LOCAL_MACHINE\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall"),
    };
    const QString wantDir = QDir::cleanPath(QDir::fromNativeSeparators(installDir));
    for (const QString &root : roots) {
        QSettings rootSettings(root, QSettings::NativeFormat);
        for (const QString &group : rootSettings.childGroups()) {
            const QString display = rootSettings.value(group + QStringLiteral("/DisplayName")).toString();
            const QString loc = rootSettings.value(group + QStringLiteral("/InstallLocation")).toString();
            if (display.compare(QStringLiteral("OrbbecSlicer"), Qt::CaseInsensitive) != 0)
                continue;
            if (QDir::cleanPath(QDir::fromNativeSeparators(loc)).compare(wantDir, Qt::CaseInsensitive) != 0)
                continue;
            keyPath = root + QLatin1Char('\\') + group;
            break;
        }
        if (!keyPath.isEmpty())
            break;
    }

    if (keyPath.isEmpty()) {
        // QIFW's key not found (e.g. old version/cleaned up): create our own and delete it on uninstall.
        // For a per-machine install (Program Files and admin), write HKLM so all users can see it; otherwise write HKCU.
        const bool perMachine = QDir::cleanPath(QDir::fromNativeSeparators(installDir))
                                    .startsWith(QStringLiteral("C:/Program Files"), Qt::CaseInsensitive);
        const QString hive = (perMachine && MSOpen::isAdmin())
                                 ? QStringLiteral("HKEY_LOCAL_MACHINE")
                                 : QStringLiteral("HKEY_CURRENT_USER");
        const QString guid = QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper();
        keyPath = hive + QStringLiteral("\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{%1}")
                      .arg(guid);
        QSettings k(keyPath, QSettings::NativeFormat);
        k.setValue(QStringLiteral("DisplayName"), QStringLiteral("OrbbecSlicer"));
        k.setValue(QStringLiteral("Publisher"), QStringLiteral("Orbbec"));
        k.sync();
        appendLog(QStringLiteral("Created own uninstall registration (%1): %2").arg(hive, keyPath));
    }
    m_selfUninstallKey = keyPath;

    // Fields needed by Programs and Features: fill in/overwrite; EstimatedSize is in KB.
    qint64 installBytes = 0;
    {
        QDirIterator it(m_installDir, QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            it.next();
            installBytes += it.fileInfo().size();
        }
    }
    QSettings entry(keyPath, QSettings::NativeFormat);
    if (entry.value(QStringLiteral("DisplayName")).toString().isEmpty())
        entry.setValue(QStringLiteral("DisplayName"), QStringLiteral("OrbbecSlicer"));
    if (entry.value(QStringLiteral("Publisher")).toString().isEmpty())
        entry.setValue(QStringLiteral("Publisher"), QStringLiteral("Orbbec"));
    if (entry.value(QStringLiteral("DisplayVersion")).toString().isEmpty())
        entry.setValue(QStringLiteral("DisplayVersion"), QStringLiteral(ORBBEC_SETUP_VERSION));
    entry.setValue(QStringLiteral("InstallLocation"), installDir);
    entry.setValue(QStringLiteral("UninstallString"), uninstallString);
    entry.setValue(QStringLiteral("QuietUninstallString"), quietString);
    entry.setValue(QStringLiteral("DisplayIcon"), dest);
    entry.setValue(QStringLiteral("EstimatedSize"), static_cast<int>(qMin<qint64>(installBytes / 1024, INT_MAX)));
    entry.setValue(QStringLiteral("NoModify"), 1);
    entry.setValue(QStringLiteral("NoRepair"), 1);
    entry.sync();
    if (entry.status() != QSettings::NoError)
        appendLog(QStringLiteral("Failed to write uninstall registration (%1): %2").arg(int(entry.status())).arg(keyPath));

    QSettings marker(QStringLiteral("HKEY_CURRENT_USER\\Software\\Orbbec\\OrbbecSlicer"),
                     QSettings::NativeFormat);
    marker.setValue(QStringLiteral("Uninstaller"), dest);
    marker.setValue(QStringLiteral("UninstallKey"), m_selfUninstallKey);
    marker.sync();

    const QString programs = QStandardPaths::writableLocation(QStandardPaths::ApplicationsLocation);
    const QString lnk = QDir(QDir(programs).filePath(QStringLiteral("OrbbecSlicer")))
                            .filePath(QStringLiteral("Uninstall OrbbecSlicer.lnk"));
    const QString args = QStringLiteral("--uninstall --install-dir \"%1\"").arg(installDir);
    const bool shortOk = createShellLink(lnk, dest, args, installDir);
    appendLog(QStringLiteral("Uninstall entry: %1 (shortcut %2)")
                  .arg(QDir::toNativeSeparators(dest), shortOk ? QStringLiteral("created") : QStringLiteral("creation failed")));
}

void SetupEngine::removeUninstallerRegistration()
{
    const QString programs = QStandardPaths::writableLocation(QStandardPaths::ApplicationsLocation);
    const QString lnkDir = QDir(programs).filePath(QStringLiteral("OrbbecSlicer"));
    for (const QString &name : {QStringLiteral("Uninstall OrbbecSlicer.lnk"), QStringLiteral("OrbbecSlicer.lnk")}) {
        const QString lnk = QDir(lnkDir).filePath(name);
        // Do not check exists first: under some sandboxes/filter drivers stat fails but the file is still there; delete directly.
        if (QFile::remove(lnk))
            appendLog(QStringLiteral("Deleted Start menu shortcut: %1").arg(QDir::toNativeSeparators(lnk)));
    }
    QDir().rmdir(lnkDir);

    QSettings marker(QStringLiteral("HKEY_CURRENT_USER\\Software\\Orbbec\\OrbbecSlicer"),
                     QSettings::NativeFormat);
    const QString selfKey = marker.value(QStringLiteral("UninstallKey")).toString();
    marker.remove(QStringLiteral("Uninstaller"));
    marker.remove(QStringLiteral("UninstallKey"));
    marker.sync();

    if (!selfKey.isEmpty()) {
#ifdef Q_OS_WIN
        struct HivePrefix { const char *prefix; HKEY hive; };
        const HivePrefix prefixes[] = {
            {"HKEY_CURRENT_USER\\", HKEY_CURRENT_USER},
            {"HKEY_LOCAL_MACHINE\\", HKEY_LOCAL_MACHINE},
        };
        bool deleted = false;
        for (const HivePrefix &p : prefixes) {
            const QString prefix = QString::fromLatin1(p.prefix);
            if (!selfKey.startsWith(prefix, Qt::CaseInsensitive))
                continue;
            const std::wstring sub = selfKey.mid(prefix.size()).toStdWString();
            const LONG rc = RegDeleteKeyW(p.hive, sub.c_str());
            appendLog(QStringLiteral("Deleting uninstall registration (%1): %2")
                          .arg(rc == ERROR_SUCCESS ? QStringLiteral("succeeded")
                                                   : (rc == ERROR_FILE_NOT_FOUND ? QStringLiteral("already deleted by pr")
                                                                                 : QStringLiteral("failed %1").arg(rc)),
                               selfKey));
            deleted = true;
            break;
        }
        Q_UNUSED(deleted)
#endif
        m_selfUninstallKey.clear();
    }
}

void SetupEngine::cleanupUserDataIfRequested()
{
    // First delete the user-visible uninstall entries (shortcut/self-created registration), then restore install options (desktop shortcut/associations), and finally clean data.
    removeUninstallerRegistration();
    revertInstallOptions();
    // Data cleanup is the shell's responsibility: QIFW only handles program files.
    // The product data directory is taken by the app's own org/app name (Orbbec/OrbbecSlicer); do not use the installer's own
    // AppDataLocation (that is Orbbec/OrbbecSlicerSetup, deleting it only deletes installer logs).
    // Test hook: ORBBEC_SETUP_DATA_ROOT redirects both data roots under out/.
    const QString dataRoot = qEnvironmentVariable("ORBBEC_SETUP_DATA_ROOT");
    const QString appData = dataRoot.isEmpty()
        ? QDir(qEnvironmentVariable("APPDATA")).filePath(QStringLiteral("Orbbec/OrbbecSlicer"))
        : QDir(dataRoot).filePath(QStringLiteral("Roaming/Orbbec/OrbbecSlicer"));
    const QString localData = dataRoot.isEmpty()
        ? QDir(qEnvironmentVariable("LOCALAPPDATA")).filePath(QStringLiteral("Orbbec/OrbbecSlicer"))
        : QDir(dataRoot).filePath(QStringLiteral("Local/Orbbec/OrbbecSlicer"));

    // Both scopes clear sensitive credentials: clean by known filenames (skip if absent).
    const QStringList credentials = {
        QStringLiteral("credentials.json"), QStringLiteral("tokens.json"),
        QStringLiteral("session.json"), QStringLiteral("lan-access-code.txt"),
    };
    for (const QString &dir : {appData, localData}) {
        for (const QString &name : credentials) {
            const QString f = QDir(dir).filePath(name);
            if (QFileInfo::exists(f) && QFile::remove(f))
                appendLog(QStringLiteral("Cleared credentials: %1").arg(QDir::toNativeSeparators(f)));
        }
    }

    if (m_keepDataDir) {
        appendLog(QStringLiteral("Keeping user data directory: %1").arg(QDir::toNativeSeparators(appData)));
        return;
    }
    if (m_removeAllData) {
        for (const QString &dir : {appData, localData}) {
            if (QFileInfo::exists(dir)) {
                QDir(dir).removeRecursively();
                appendLog(QStringLiteral("Deleted user data directory: %1").arg(QDir::toNativeSeparators(dir)));
            }
        }
    } else {
        // Keep personal data: clear cache/logs (local), keep presets and preferences (roaming).
        if (QFileInfo::exists(localData)) {
            QDir(localData).removeRecursively();
            appendLog(QStringLiteral("Deleted cache and logs: %1").arg(QDir::toNativeSeparators(localData)));
        }
        appendLog(QStringLiteral("Keeping personal data directory: %1").arg(QDir::toNativeSeparators(appData)));
    }
}

bool SetupEngine::cleanupInstallDirAfterUninstall(QString &residual)
{
    residual.clear();
    const QString dir = QDir::toNativeSeparators(m_installDir);
    if (dir.isEmpty()) {
        residual = QStringLiteral("(install directory is empty)");
        return false;
    }
    if (!QFileInfo::exists(dir)) {
        appendLog(QStringLiteral("Uninstall complete: install directory no longer exists %1").arg(dir));
        return true;
    }

    // maintenancetool.exe is held by itself while pr runs; the handle may not be released at the moment of exit either.
    // 5 × 150 ms covers common antivirus / indexer delays; if it still fails, report residue.
    for (int attempt = 1; attempt <= 5; ++attempt) {
        QDir(dir).removeRecursively();
        if (!QFileInfo::exists(dir)) {
            appendLog(QStringLiteral("Uninstall complete: deleted install directory %1").arg(dir));
            return true;
        }
        if (attempt < 5)
            QThread::msleep(150);
    }

    QStringList leftovers;
    QDir base(dir);
    QDirIterator it(dir, QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot,
                    QDirIterator::Subdirectories);
    while (it.hasNext() && leftovers.size() < 20) {
        it.next();
        leftovers << base.relativeFilePath(it.filePath());
    }
    residual = leftovers.isEmpty() ? QStringLiteral("(directory not empty)") : leftovers.join(QStringLiteral("; "));
    appendLog(QStringLiteral("Uninstall complete but install directory still has residue %1: %2").arg(dir, residual));
    return false;
}
