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
// 目录探测缓存：OptionsPage 里 dirProblem 是绑定，每次属性改动都会重算；ACL 判断要枚举
// 安全描述符，不高频重复做。键含目标目录与决定结果的祖先目录及其修改时间，
// 目录被外部改动（新建、删除、改权限外的重建）后重新判断。
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
    // ProgramFiles 默认；Problems 时退回 LOCALAPPDATA（非管理员安装的场景）。
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
        return QStringLiteral("请填写安装位置");

    const QFileInfo info(path);
    QString dir = info.absoluteFilePath();
    // 向上找到第一个存在的祖先：允许创建多层新目录。
    while (!QFileInfo(dir).exists() && dir.length() > 3)
        dir = QFileInfo(dir).absolutePath();

    // 缓存键带上祖先目录的修改时间：新目录建出来或被删掉时时间会变，缓存自然失效。
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
        return remember(QStringLiteral("%1 不是目录").arg(QDir::toNativeSeparators(dir)));
    if (QFileInfo(path).exists() && !QFileInfo(path).isDir())
        return remember(QStringLiteral("%1 已存在且不是目录").arg(QDir::toNativeSeparators(path)));

    // 探测写权限放在实际会被写入的目录：目标已存在就测目标本身（目标内部被限制写入时也
    // 测得到）；目标还不存在就测最近存在的祖先"能否新建子目录"（Program Files 这类位置
    // 本身就不允许普通用户建目录，结果一致）。
    // 不用"写一个临时文件"来判断：见 msopen.h——普通用户往受保护目录里建文件会被
    // 提升回退"放行"，而安装程序真正写入时并不会。
    const QString target = info.isDir() ? info.absoluteFilePath() : dir;
    const MSOpen::Access access = MSOpen::effectiveAccess(target);
    switch (access) {
    case MSOpen::Access::ReadOnly:
        return remember(QStringLiteral("%1 不可写，请换一个位置或以管理员身份运行安装程序")
                            .arg(QDir::toNativeSeparators(info.absoluteFilePath())));
    case MSOpen::Access::Missing:
        return remember(QStringLiteral("%1 不可用").arg(QDir::toNativeSeparators(info.absoluteFilePath())));
    case MSOpen::Access::Writable:
    case MSOpen::Access::Unknown:
        break;
    }
    // 权限判断不出来时（旧系统、非本地卷）再试一次真实写入，作为兜底。
    if (access == MSOpen::Access::Unknown) {
        const QString probe = QDir(target).filePath(
            QStringLiteral(".orbbec-write-probe-%1").arg(QCoreApplication::applicationPid()));
        QFile f(probe);
        if (!f.open(QIODevice::WriteOnly))
            return remember(QStringLiteral("%1 不可写，请换一个位置或以管理员身份运行安装程序")
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
    // QIFW 的注册表项与安装目录里的快捷信息都可用；这里两条路都查，取先命中的。
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
        // 退化：默认安装目录里存在 maintenancetool.exe 即视为已安装，版本读其 metadata。
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
    // 安装日志放在安装器自己的日志目录下，而不是安装目标里：卸载后仍可追溯。
    const QString logs = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
                         + QStringLiteral("/logs");
    QDir().mkpath(logs);
    return QDir::toNativeSeparators(logs);
}
