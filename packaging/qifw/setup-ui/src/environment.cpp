#include "environment.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QSettings>
#include <QStandardPaths>
#include <QStorageInfo>
#include <QVariantMap>
#include <QCoreApplication>
#include <QHash>
#include <QMutex>
#include <QMutexLocker>

#include "msopen.h"

Environment::Environment(QObject *parent) : QObject(parent) {}

namespace {
// Directory probe cache: dirProblem in OptionsPage is a binding recomputed on every
// property change; ACL checks enumerate security descriptors, so avoid repeating them
// frequently. The key includes the target directory and the ancestor directory that
// determines the result plus its modification time, so the decision is re-evaluated after
// external changes (creation, deletion, or recreation beyond permission changes).
struct ProbeCacheEntry {
    qint64 stamp = -1;
    QString result;
};
QHash<QString, ProbeCacheEntry> &probeCache()
{
    static QHash<QString, ProbeCacheEntry> cache;
    return cache;
}
QMutex &probeCacheMutex()
{
    static QMutex m;
    return m;
}
} // namespace

QString Environment::defaultInstallDir() const
{
#ifdef Q_OS_WIN
    // ProgramFiles by default; fall back to LOCALAPPDATA on Problems (non-admin install).
    QString pf = qEnvironmentVariable("ProgramFiles");
    if (pf.isEmpty())
        pf = QStandardPaths::writableLocation(QStandardPaths::ApplicationsLocation);
    if (!pf.isEmpty())
        return QDir::toNativeSeparators(pf + QStringLiteral("/OrbbecSlicer"));
#endif
    return QDir::toNativeSeparators(
        QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation) + QStringLiteral("/OrbbecSlicer"));
}

QString Environment::probeDirectory(const QString &path) const
{
    if (path.trimmed().isEmpty())
        return tr("Please specify an install location");

    const QFileInfo info(path);
    QString dir = info.absoluteFilePath();
    // Walk up to the first existing ancestor: allows creating several new directory levels.
    while (!QFileInfo(dir).exists() && dir.length() > 3)
        dir = QFileInfo(dir).absolutePath();

    // The cache key includes the ancestor directory's modification time: it changes when a
    // new directory is created or deleted, so the cache is invalidated naturally.
    const QFileInfo ancestor(dir);
    const QString key = dir + QLatin1Char('\n') + path.trimmed();
    const qint64 stamp = ancestor.lastModified().toMSecsSinceEpoch()
                         ^ (ancestor.isDir() ? 1 : 0);
    {
        QMutexLocker lock(&probeCacheMutex());
        const auto it = probeCache().constFind(key);
        if (it != probeCache().constEnd() && it->stamp == stamp)
            return it->result;
    }
    const auto remember = [&key, stamp](const QString &result) {
        QMutexLocker lock(&probeCacheMutex());
        if (probeCache().size() > 64)
            probeCache().clear();
        probeCache().insert(key, ProbeCacheEntry{stamp, result});
        return result;
    };

    if (!ancestor.isDir())
        return remember(tr("%1 is not a directory").arg(QDir::toNativeSeparators(dir)));
    if (QFileInfo(path).exists() && !QFileInfo(path).isDir())
        return remember(tr("%1 already exists and is not a directory").arg(QDir::toNativeSeparators(path)));

    // Probe write permission in the directory that will actually be written: if the target
    // already exists, test the target itself (this also catches write restrictions inside
    // the target); if the target does not exist yet, test whether the nearest existing
    // ancestor can create a subdirectory (locations like Program Files already disallow
    // creating directories for regular users, giving the same result).
    // Do not use "write a temporary file" to decide: see msopen.h — a regular user creating
    // a file in a protected directory gets elevated fallback "allow", whereas the installer
    // does not when it actually writes.
    const QString target = info.isDir() ? info.absoluteFilePath() : dir;
    const MSOpen::Access access = MSOpen::effectiveAccess(target);
    switch (access) {
    case MSOpen::Access::ReadOnly:
        return remember(tr("%1 is not writable; choose another location or run the installer as administrator")
                            .arg(QDir::toNativeSeparators(info.absoluteFilePath())));
    case MSOpen::Access::Missing:
        return remember(tr("%1 is unavailable").arg(QDir::toNativeSeparators(info.absoluteFilePath())));
    case MSOpen::Access::Writable:
    case MSOpen::Access::Unknown:
        break;
    }
    // When permission cannot be determined (legacy systems, non-local volumes), try a real
    // write once as a fallback.
    if (access == MSOpen::Access::Unknown) {
        const QString probe = QDir(target).filePath(
            QStringLiteral(".orbbec-write-probe-%1").arg(QCoreApplication::applicationPid()));
        QFile f(probe);
        if (!f.open(QIODevice::WriteOnly))
            return remember(tr("%1 is not writable; choose another location or run the installer as administrator")
                                .arg(QDir::toNativeSeparators(info.absoluteFilePath())));
        f.close();
        QFile::remove(probe);
    }
    return remember(QString());
}

QString Environment::normalizeDirPath(const QString &path) const
{
    const QString t = path.trimmed();
    if (t.isEmpty())
        return QString();
    return QDir::toNativeSeparators(QDir::cleanPath(t));
}

QString Environment::installDirForParent(const QString &parent) const
{
    QString base = QDir::fromNativeSeparators(parent.trimmed());
    if (base.isEmpty())
        return QString();
    // "D:" means the current directory on drive D, not the root; append a separator then
    // cleanPath so "D:" and "D:\" are equivalent.
    if (base.size() == 2 && base.at(1) == QLatin1Char(':'))
        base += QLatin1Char('/');
    base = QDir::cleanPath(base);
    if (base.isEmpty())
        return QString();
    const QString leaf = QFileInfo(base).fileName();
    if (leaf.compare(QStringLiteral("OrbbecSlicer"), Qt::CaseInsensitive) == 0)
        return QDir::toNativeSeparators(base);
    // Drive roots ("D:/") and normal directories both go through cleanPath then native
    // separators, avoiding a combined "D:\\OrbbecSlicer".
    return QDir::toNativeSeparators(
        QDir::cleanPath(base + QLatin1Char('/') + QStringLiteral("OrbbecSlicer")));
}

QString Environment::defaultInstallParent() const
{
    return QDir::toNativeSeparators(QFileInfo(defaultInstallDir()).absolutePath());
}

QString Environment::installParentForDir(const QString &installDir) const
{
    const QString clean = normalizeDirPath(installDir);
    if (clean.isEmpty())
        return QString();
    return QDir::toNativeSeparators(QFileInfo(clean).absolutePath());
}

qint64 Environment::freeBytes(const QString &path) const
{
    QString dir = QFileInfo(path).absoluteFilePath();
    while (!QFileInfo(dir).exists() && dir.length() > 3)
        dir = QFileInfo(dir).absolutePath();
    const QStorageInfo storage(dir);
    if (!storage.isValid())
        return -1;
    return storage.bytesAvailable();
}

InstalledInfo Environment::readInstalled() const
{
    InstalledInfo info;
#ifdef Q_OS_WIN
    // Both QIFW's registry entry and the shortcut info in the install directory are
    // available; query both paths here and take the first hit.
    QSettings reg(QStringLiteral("HKEY_CURRENT_USER\\Software\\Orbbec\\OrbbecSlicer"),
                  QSettings::NativeFormat);
    if (reg.contains(QStringLiteral("InstallDir"))) {
        info.installDir = reg.value(QStringLiteral("InstallDir")).toString();
        info.version = reg.value(QStringLiteral("Version")).toString();
        info.installed = QFileInfo(info.installDir + QStringLiteral("/maintenancetool.exe")).exists();
        if (!info.installed)
            info.installDir.clear();
    }
#endif
    if (!info.installed) {
        // Fallback: treat maintenancetool.exe existing in the default install directory as
        // installed; read the version from its metadata.
        const QString dir = defaultInstallDir();
        const QFileInfo mt(dir + QStringLiteral("/maintenancetool.exe"));
        if (mt.exists()) {
            info.installed = true;
            info.installDir = QDir::toNativeSeparators(dir);
            info.version.clear();
        }
    }
    return info;
}

QVariantMap Environment::installedInfo() const
{
    const InstalledInfo info = readInstalled();
    QVariantMap m;
    m.insert(QStringLiteral("installed"), info.installed);
    m.insert(QStringLiteral("version"), info.version);
    m.insert(QStringLiteral("installDir"), info.installDir);
    return m;
}

QString Environment::appExecutablePath(const QString &installDir) const
{
    static const char *const names[] = {"ob-slicer.exe", "OrbbecSlicer.exe"};
    for (const char *name : names) {
        const QString path = QDir(installDir).filePath(QString::fromLatin1(name));
        if (QFileInfo::exists(path))
            return QDir::toNativeSeparators(path);
    }
    return QString();
}

bool Environment::launch(const QString &program, const QStringList &args) const
{
    if (program.isEmpty() || !QFileInfo::exists(program))
        return false;
    return QProcess::startDetached(program, args);
}

bool Environment::revealDirectory(const QString &path) const
{
    QDir().mkpath(path);
#ifdef Q_OS_WIN
    return QProcess::startDetached(QStringLiteral("explorer.exe"),
                                   QStringList{QDir::toNativeSeparators(path)});
#else
    return false;
#endif
}

QString Environment::logDirectory() const
{
    // Install logs go under the installer's own log directory, not the install target, so
    // they remain traceable after uninstall.
    const QString logs = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
                         + QStringLiteral("/logs");
    QDir().mkpath(logs);
    return QDir::toNativeSeparators(logs);
}
