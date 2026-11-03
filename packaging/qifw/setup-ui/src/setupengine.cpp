#include "setupengine.h"

#include "environment.h"

#include <QDateTime>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcessEnvironment>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QUuid>
#include <QTime>
#include <QTimer>
#include <QVariantMap>

#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>

#include <algorithm>

namespace {
// 文件关联的 ProgId 沿用原 NSIS 方案的命名（BrandedMaintenance.nsh），升级/卸载时能对上。
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

// .3mf 记成"项目"，.stl 记成"模型"，与产品里的说法一致。
QString typeName(const QString &ext)
{
    return ext == QLatin1String(".3mf") ? QObject::tr("OrbbecSlicer 项目")
                                        : QObject::tr("OrbbecSlicer 模型");
}

// 关联图标的来源：优先用系统为 exe 登记的应用图标（带完整路径与索引），取不到再用
// exe 自身的图标。返回值直接写进 ProgId\DefaultIcon。
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

// 按选择写入（enabled）或撤回（!enabled）一种扩展名的关联。
// 与 NSIS 方案一致：只动 HKCU\Software\Classes，不改 Windows 自身的 UserChoice；
// 关联前把该类型原来的默认程序记在 Software\Orbbec\OrbbecSlicer\Assoc 下，撤回时还原。
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
    } else if (record.contains(savedKey)) {
        const QString previous = record.value(savedKey).toString();
        if (previous.isEmpty())
            type.remove(QStringLiteral("."));
        else
            type.setValue(QStringLiteral("."), previous);
        type.remove(QStringLiteral("OpenWithProgids/") + progId);
        type.sync();
        record.remove(savedKey);
        QSettings(classesKey(progId), QSettings::NativeFormat).clear();
    }
    record.sync();
}

// QIFW 静默安装的完整参数：无人值守、不弹许可/消息框、缓存与目标都可指定。
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
        // 拿不到具体百分比时按阶段权重缓慢推进，但永不在引擎结束前到 99%。
        if (!m_busy || m_progress >= 99)
            return;
        if (m_phase == QStringLiteral("写入程序文件"))
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
    // 进程被强制结束（应用退出）时把旧程序目录恢复回去。
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
        emit finished(3, QStringLiteral("已有任务在进行"));
        return;
    }
    if (!QFileInfo::exists(program)) {
        const QString msg = QStringLiteral("找不到安装引擎：%1").arg(QDir::toNativeSeparators(program));
        appendLog(msg);
        restoreBackup();
        emit finished(2, msg);
        return;
    }

    m_busy = true;
    m_cancelRequested = false;
    m_pendingLine.clear();
    setProgress(0);
    m_phase = phase;
    emit phaseChanged();
    m_detail = QStringLiteral("正在准备组件");
    emit detailChanged();
    emit busyChanged();

    appendLog(QStringLiteral("引擎: %1").arg(QDir::toNativeSeparators(program)));
    appendLog(QStringLiteral("参数: %1").arg(args.join(QLatin1Char(' '))));

    m_proc = new QProcess(this);
    m_proc->setProcessChannelMode(QProcess::MergedChannels);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    // 子进程同样以最小平台启动：不给用户任何 QIFW 自己的窗口。
    env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("minimal"));
    m_proc->setProcessEnvironment(env);
    connect(m_proc, &QProcess::readyReadStandardOutput, this, &SetupEngine::onReadyRead);
    connect(m_proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            &SetupEngine::onFinished);
    connect(m_proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError err) {
        if (err != QProcess::FailedToStart)
            return;
        const QString msg = QStringLiteral("引擎无法启动：%1").arg(m_proc ? m_proc->errorString() : QString());
        appendLog(msg);
        m_ticker->stop();
        m_busy = false;
        emit busyChanged();
        restoreBackup();
        emit finished(2, msg);
    });
    m_proc->start(program, args);
    m_ticker->start();
}

bool SetupEngine::beginReplaceExisting()
{
    // 维护（修复/升级/降级）：QIFW 的 installerbase 遇到"目录里已有安装"会直接
    // TargetDirectoryInUse 失败，所以先把旧程序目录改名备份，再按新安装写入。
    // 失败/取消时把备份改回去，保证原版本仍可启动。
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
        appendLog(QStringLiteral("备份旧安装目录失败：%1 → %2").arg(QDir::toNativeSeparators(m_installDir),
                                                              QDir::toNativeSeparators(m_backupDir)));
        m_backupDir.clear();
        return false;
    }
    appendLog(QStringLiteral("维护：旧程序目录已备份到 %1").arg(QDir::toNativeSeparators(m_backupDir)));
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
    appendLog(ok ? QStringLiteral("维护失败：已恢复原程序目录")
                 : QStringLiteral("维护失败：恢复原程序目录失败，备份仍在 %1")
                       .arg(QDir::toNativeSeparators(m_backupDir)));
    m_backupDir.clear();
}

void SetupEngine::dropBackup()
{
    if (m_backupDir.isEmpty())
        return;
    QDir(m_backupDir).removeRecursively();
    appendLog(QStringLiteral("维护完成：已删除旧程序目录备份 %1").arg(QDir::toNativeSeparators(m_backupDir)));
    m_backupDir.clear();
}

void SetupEngine::cleanupAfterCancel()
{
    // 取消后清掉本次写入：
    //  - 安装前目录不存在：整目录删除；
    //  - 目录本来就有（含已安装版本）：已由 restoreBackup 恢复，无需再动；
    //  - 目录存在但不是安装目录：只删本次可能写出的部分文件由 QIFW 自己回滚，这里不碰。
    if (!m_targetExisted) {
        const bool ok = QDir(m_installDir).removeRecursively();
        appendLog(ok ? QStringLiteral("已取消：删除本次创建的安装目录 %1").arg(QDir::toNativeSeparators(m_installDir))
                     : QStringLiteral("已取消：安装目录删除失败，请手动清理 %1").arg(QDir::toNativeSeparators(m_installDir)));
    } else {
        appendLog(QStringLiteral("已取消：目标目录在安装前已存在，保留未删除"));
    }
}

void SetupEngine::startInstall(const QString &targetDir, const QVariantMap &options)
{
    if (m_payloadPath.isEmpty() || !QFileInfo::exists(m_payloadPath)) {
        const QString msg = QStringLiteral("安装包负载不存在：%1").arg(QDir::toNativeSeparators(m_payloadPath));
        appendLog(msg);
        emit finished(2, msg);
        return;
    }
    m_uninstallMode = false;
    m_installDir = QDir::toNativeSeparators(targetDir);
    m_targetExisted = QFileInfo::exists(m_installDir);
    m_cacheDir = QDir(QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation))
                     .filePath(QStringLiteral("installer-cache"));
    QDir().mkpath(m_cacheDir);

    if (!beginReplaceExisting()) {
        const QString msg = QStringLiteral("无法准备维护安装目录：%1").arg(m_installDir);
        appendLog(msg);
        emit finished(4, msg);
        return;
    }
    QStringList args = qifwInstallArgs(m_installDir, m_cacheDir);
    // 注：QIFW 4.11 的 installerbase 没有覆盖开关（-x 会被判为 Unknown option）；
    // 覆盖/修复由维护入口与 -t 指向同一目录完成，这里不再追加多余参数。
    m_shortcutDesktop = options.value(QStringLiteral("shortcutDesktop")).toBool();
    m_assoc3mf = options.value(QStringLiteral("assoc3mf")).toBool();
    m_assocStl = options.value(QStringLiteral("assocStl")).toBool();
    m_launchAfterInstall = options.value(QStringLiteral("launchAfterInstall")).toBool();
    appendLog(QStringLiteral("安装选项: 快捷方式=%1 .3mf=%2 .stl=%3 完成后启动=%4")
                  .arg(m_shortcutDesktop).arg(m_assoc3mf).arg(m_assocStl)
                  .arg(m_launchAfterInstall));
    startProcess(m_payloadPath, args, QStringLiteral("正在验证安装包"));
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
        // 安装目录已被手工删除：不需要 maintenancetool，直接清入口与用户数据。
        appendLog(QStringLiteral("安装目录中未找到 maintenancetool.exe，跳过程序文件移除"));
        m_uninstallMode = true;
        cleanupUserDataIfRequested();
        // 目录是空的就顺手删掉；里面还有用户文件时保留。
        if (QFileInfo::exists(m_installDir))
            QDir().rmdir(m_installDir);
        emit finished(0, QStringLiteral("程序文件已不存在，已清理卸载登记与用户数据"));
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
                 QStringLiteral("正在移除程序文件"));
}

void SetupEngine::cancel()
{
    if (!m_busy || !m_proc)
        return;
    m_cancelRequested = true;
    m_detail = QStringLiteral("正在取消…");
    emit detailChanged();
    appendLog(QStringLiteral("用户请求取消"));
    m_proc->terminate();
    // 3 秒内没退出则强杀：QIFW 对 SIGTERM 的处理不保证。
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
    // 只用于展示：QIFW 的进度输出格式不稳定，按关键字归到三个阶段。
    QString next = m_phase;
    if (!m_uninstallMode) {
        if (line.contains(QStringLiteral("extract"), Qt::CaseInsensitive)
            || line.contains(QStringLiteral("Extracting"), Qt::CaseInsensitive)) {
            next = QStringLiteral("写入程序文件");
        } else if (line.contains(QStringLiteral("branding"), Qt::CaseInsensitive)
                   || line.contains(QStringLiteral("shortcut"), Qt::CaseInsensitive)) {
            next = QStringLiteral("完成配置");
        }
    }
    if (next != m_phase) {
        m_phase = next;
        emit phaseChanged();
        appendLog(QStringLiteral("阶段: %1").arg(m_phase));
        if (!m_uninstallMode) {
            setProgress(m_phase == QStringLiteral("写入程序文件") ? 8 : m_progress);
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
        // 收尾：把缓冲区里最后没有换行的一行也读出来。
        m_pendingLine += QString::fromLocal8Bit(m_proc->readAllStandardOutput());
        if (!m_pendingLine.trimmed().isEmpty())
            appendLog(m_pendingLine.trimmed());
        m_pendingLine.clear();
    }
    const bool crashed = (status == QProcess::CrashExit);
    appendLog(QStringLiteral("引擎退出: code=%1 status=%2").arg(exitCode).arg(crashed ? "crash" : "normal"));

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
                      QStringLiteral("安装引擎以 %1 退出").arg(crashed ? QStringLiteral("非正常状态") : QString::number(exitCode)));
        return;
    }

    if (m_uninstallMode)
        cleanupUserDataIfRequested();
    else {
        // 维护成功：新程序目录已就位，旧备份可以删除。
        dropBackup();
        applyInstallOptions();
        installUninstaller();
    }
    setProgress(100);
    emit finished(0, m_uninstallMode ? QStringLiteral("卸载完成") : QStringLiteral("安装完成"));
}

void SetupEngine::applyInstallOptions()
{
    // QIFW 的包不带组件脚本、不读外壳的选项，所以快捷方式与文件关联在这里补：
    //   - 桌面快捷方式：%USERPROFILE%\Desktop\OrbbecSlicer.lnk（卸载走 QIFW 的干净卸载，
    //     漏掉的这一项在 maintenancetool 移除目录前不会被清理）；
    //   - 文件关联：HKCU\Software\Classes，只改当前用户，不需要管理员权限。
    // 任一项失败只记日志，不把已成功的安装判成失败。
    // 主程序名随产品而异：当前 staging 里是 ob-slicer.exe（历史包是 OrbbecSlicer.exe）。
    const QString exe = m_env ? m_env->appExecutablePath(m_installDir) : QString();
    if (exe.isEmpty()) {
        appendLog(QStringLiteral("安装目录中未找到主程序（ob-slicer.exe / OrbbecSlicer.exe），跳过快捷方式与文件关联"));
        return;
    }
    const QString exeNative = QDir::toNativeSeparators(exe);

    if (m_shortcutDesktop)
        ensureDesktopShortcut(m_installDir);

    QSettings record(QStringLiteral("HKEY_CURRENT_USER\\Software\\Orbbec\\OrbbecSlicer\\Assoc"),
                     QSettings::NativeFormat);
    setAssociation(record, QStringLiteral(".3mf"), m_assoc3mf, exe);
    setAssociation(record, QStringLiteral(".stl"), m_assocStl, exe);
    appendLog(QStringLiteral("文件关联: .3mf=%1 .stl=%2").arg(m_assoc3mf).arg(m_assocStl));
}

bool SetupEngine::ensureDesktopShortcut(const QString &installDir)
{
    const QString exe = m_env ? m_env->appExecutablePath(installDir) : QString();
    if (exe.isEmpty()) {
        appendLog(QStringLiteral("无法创建桌面快捷方式：安装目录中没有主程序（%1）")
                      .arg(QDir::toNativeSeparators(installDir)));
        return false;
    }
    const QString desktop = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
    if (desktop.isEmpty()) {
        appendLog(QStringLiteral("无法创建桌面快捷方式：取不到桌面目录"));
        return false;
    }
    const QString lnk = QDir(desktop).filePath(QStringLiteral("OrbbecSlicer.lnk"));
    const bool ok = createShellLink(lnk, exe, QString(), QDir::toNativeSeparators(installDir));
    appendLog(ok ? QStringLiteral("已创建桌面快捷方式: %1 → %2")
                       .arg(QDir::toNativeSeparators(lnk), QDir::toNativeSeparators(exe))
                 : QStringLiteral("创建桌面快捷方式失败: %1").arg(QDir::toNativeSeparators(lnk)));
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

void SetupEngine::installUninstaller()
{
    // 安装/维护成功后：把自包含卸载器部署到用户目录，并把系统卸载入口指向它。
    // QIFW 的 maintenancetool.exe 保留在安装目录里做维护/更新，但不再作为用户可见入口。
    const QString installDir = QDir::toNativeSeparators(m_installDir);
    if (m_uninstallerSource.isEmpty() || !QFileInfo::exists(m_uninstallerSource)) {
        appendLog(QStringLiteral("未提供卸载器源文件，跳过卸载入口部署"));
        return;
    }
    // 测试钩子：打包回路把数据根重定向到 out/ 下，避免动到本机真实用户数据。
    const QString dataRoot = qEnvironmentVariable("ORBBEC_SETUP_DATA_ROOT");
    const QString local = dataRoot.isEmpty() ? qEnvironmentVariable("LOCALAPPDATA")
                                             : QDir(dataRoot).filePath(QStringLiteral("Local"));
    if (local.isEmpty()) {
        appendLog(QStringLiteral("LOCALAPPDATA 为空，跳过卸载入口部署"));
        return;
    }
    const QString dir = QDir(local).filePath(QStringLiteral("Orbbec/OrbbecSlicer/uninstaller"));
    QDir().mkpath(dir);
    const QString dest = QDir::toNativeSeparators(
        QDir(dir).filePath(QStringLiteral("OrbbecSlicerUninstaller.exe")));
    if (QFileInfo::exists(dest) && !QFile::remove(dest)) {
        appendLog(QStringLiteral("无法覆盖旧卸载器: %1").arg(QDir::toNativeSeparators(dest)));
        return;
    }
    if (!QFile::copy(m_uninstallerSource, dest)) {
        appendLog(QStringLiteral("复制卸载器失败: %1 → %2").arg(QDir::toNativeSeparators(m_uninstallerSource),
                                                          QDir::toNativeSeparators(dest)));
        return;
    }
    m_uninstallerDeployed = QDir::toNativeSeparators(dest);

    const QString uninstallString = QStringLiteral("\"%1\" --uninstall --install-dir \"%2\"")
                                        .arg(dest, installDir);
    const QString quietString = uninstallString + QStringLiteral(" --silent");

    // 找 QIFW 生成的卸载登记（DisplayName + InstallLocation 匹配）。
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
        // 找不到 QIFW 的键（例如旧版/被清理过）：自建一个，卸载时再删。
        const QString guid = QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper();
        keyPath = QStringLiteral("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{%1}")
                      .arg(guid);
        QSettings k(keyPath, QSettings::NativeFormat);
        k.setValue(QStringLiteral("DisplayName"), QStringLiteral("OrbbecSlicer"));
        k.setValue(QStringLiteral("DisplayVersion"), QStringLiteral(ORBBEC_SETUP_VERSION));
        k.setValue(QStringLiteral("Publisher"), QStringLiteral("Orbbec"));
        k.setValue(QStringLiteral("InstallLocation"), installDir);
        k.setValue(QStringLiteral("NoModify"), 1);
        k.setValue(QStringLiteral("NoRepair"), 1);
        k.sync();
        appendLog(QStringLiteral("已自建卸载登记: %1").arg(keyPath));
    }
    m_selfUninstallKey = keyPath;

    QSettings entry(keyPath, QSettings::NativeFormat);
    entry.setValue(QStringLiteral("UninstallString"), uninstallString);
    entry.setValue(QStringLiteral("QuietUninstallString"), quietString);
    entry.setValue(QStringLiteral("DisplayIcon"), dest);
    entry.sync();

    QSettings marker(QStringLiteral("HKEY_CURRENT_USER\\Software\\Orbbec\\OrbbecSlicer"),
                     QSettings::NativeFormat);
    marker.setValue(QStringLiteral("Uninstaller"), dest);
    marker.setValue(QStringLiteral("UninstallKey"), m_selfUninstallKey);
    marker.sync();

    const QString programs = QStandardPaths::writableLocation(QStandardPaths::ApplicationsLocation);
    const QString lnk = QDir(QDir(programs).filePath(QStringLiteral("OrbbecSlicer")))
                            .filePath(QStringLiteral("卸载 OrbbecSlicer.lnk"));
    const QString args = QStringLiteral("--uninstall --install-dir \"%1\"").arg(installDir);
    const bool shortOk = createShellLink(lnk, dest, args, installDir);
    appendLog(QStringLiteral("卸载入口: %1（快捷方式 %2）")
                  .arg(QDir::toNativeSeparators(dest), shortOk ? QStringLiteral("已创建") : QStringLiteral("创建失败")));
}

void SetupEngine::removeUninstallerRegistration()
{
    const QString programs = QStandardPaths::writableLocation(QStandardPaths::ApplicationsLocation);
    const QString lnkDir = QDir(programs).filePath(QStringLiteral("OrbbecSlicer"));
    const QString lnk = QDir(lnkDir).filePath(QStringLiteral("卸载 OrbbecSlicer.lnk"));
    if (QFileInfo::exists(lnk) && QFile::remove(lnk))
        appendLog(QStringLiteral("已删除卸载快捷方式: %1").arg(QDir::toNativeSeparators(lnk)));
    QDir().rmdir(lnkDir);

    QSettings marker(QStringLiteral("HKEY_CURRENT_USER\\Software\\Orbbec\\OrbbecSlicer"),
                     QSettings::NativeFormat);
    const QString selfKey = marker.value(QStringLiteral("UninstallKey")).toString();
    marker.remove(QStringLiteral("Uninstaller"));
    marker.remove(QStringLiteral("UninstallKey"));
    marker.sync();

    if (!selfKey.isEmpty()) {
#ifdef Q_OS_WIN
        const QString prefix = QStringLiteral("HKEY_CURRENT_USER\\");
        if (selfKey.startsWith(prefix, Qt::CaseInsensitive)) {
            const std::wstring sub = selfKey.mid(prefix.size()).toStdWString();
            const LONG rc = RegDeleteKeyW(HKEY_CURRENT_USER, sub.c_str());
            if (rc == ERROR_SUCCESS)
                appendLog(QStringLiteral("已删除卸载登记: %1").arg(selfKey));
            else
                appendLog(QStringLiteral("删除卸载登记失败（%1）: %2").arg(rc).arg(selfKey));
        }
#endif
        m_selfUninstallKey.clear();
    }
}

void SetupEngine::cleanupUserDataIfRequested()
{
    // 先删用户可见的卸载入口（快捷方式/自建登记），再做数据清理。
    removeUninstallerRegistration();
    // 数据清理由外壳负责：QIFW 只管程序文件。
    // 产品数据目录按应用自身的 org/app 名（Orbbec/OrbbecSlicer）取，不要用安装器自己的
    // AppDataLocation（那是 Orbbec/OrbbecSlicerSetup，删它只会删安装器日志）。
    // 测试钩子：ORBBEC_SETUP_DATA_ROOT 把两个数据根都重定向到 out/ 下。
    const QString dataRoot = qEnvironmentVariable("ORBBEC_SETUP_DATA_ROOT");
    const QString appData = dataRoot.isEmpty()
        ? QDir(qEnvironmentVariable("APPDATA")).filePath(QStringLiteral("Orbbec/OrbbecSlicer"))
        : QDir(dataRoot).filePath(QStringLiteral("Roaming/Orbbec/OrbbecSlicer"));
    const QString localData = dataRoot.isEmpty()
        ? QDir(qEnvironmentVariable("LOCALAPPDATA")).filePath(QStringLiteral("Orbbec/OrbbecSlicer"))
        : QDir(dataRoot).filePath(QStringLiteral("Local/Orbbec/OrbbecSlicer"));

    // 两种范围都清敏感凭据：按已知的文件名清理（没有就跳过）。
    const QStringList credentials = {
        QStringLiteral("credentials.json"), QStringLiteral("tokens.json"),
        QStringLiteral("session.json"), QStringLiteral("lan-access-code.txt"),
    };
    for (const QString &dir : {appData, localData}) {
        for (const QString &name : credentials) {
            const QString f = QDir(dir).filePath(name);
            if (QFileInfo::exists(f) && QFile::remove(f))
                appendLog(QStringLiteral("已清除凭据: %1").arg(QDir::toNativeSeparators(f)));
        }
    }

    if (m_keepDataDir) {
        appendLog(QStringLiteral("保留用户数据目录: %1").arg(QDir::toNativeSeparators(appData)));
        return;
    }
    if (m_removeAllData) {
        for (const QString &dir : {appData, localData}) {
            if (QFileInfo::exists(dir)) {
                QDir(dir).removeRecursively();
                appendLog(QStringLiteral("删除用户数据目录: %1").arg(QDir::toNativeSeparators(dir)));
            }
        }
    } else {
        // 保留个人数据：清缓存/日志（local），保留预设与偏好（roaming）。
        if (QFileInfo::exists(localData)) {
            QDir(localData).removeRecursively();
            appendLog(QStringLiteral("删除缓存与日志: %1").arg(QDir::toNativeSeparators(localData)));
        }
        appendLog(QStringLiteral("保留个人数据目录: %1").arg(QDir::toNativeSeparators(appData)));
    }
}
