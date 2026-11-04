#include "setuphost.h"

#include "environment.h"
#include "setupengine.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QProcess>
#include <QStandardPaths>
#include <QTimer>

#include <cstring>

namespace {
// 追加在 PE 末尾的数据区索引（见 design.md D3 与 tasks 7.1）：
//   [payload 字节][magic 8B "OSUI1"][offset 8B][length 8B][sha256 32B][version 4B]
// 全部小端；magic 之后的 4 字节是保留位，与任务书里的 "magic OSUI1" 对齐。
constexpr char kMagic[8] = {'O', 'S', 'U', 'I', '1', 0, 0, 0};
constexpr qint64 kTrailerSize = 8 + 8 + 8 + 32 + 4;

qint64 readInt64(const QByteArray &data, int offset)
{
    qint64 v = 0;
    std::memcpy(&v, data.constData() + offset, sizeof(v));
    return v;
}
} // namespace

SetupHost::SetupHost(Environment *env, QObject *parent) : QObject(parent), m_env(env)
{
    m_engine = new SetupEngine(env, this);
    // 自包含卸载器的源文件由 Setup.exe 启动器在解压后传入（安装成功后部署）。
    const QStringList args = QCoreApplication::arguments();
    for (int i = 1; i + 1 < args.size(); ++i) {
        if (args.at(i) == QStringLiteral("--uninstaller"))
            m_engine->setUninstallerPath(args.at(i + 1));
    }
    locatePayload();
    schedulePayloadCleanup();
}

SetupHost::~SetupHost() = default;

bool SetupHost::selfTestOptions() const
{
    return qEnvironmentVariableIsSet("ORBBEC_SETUP_SELFTEST_OPTIONS");
}

QString SetupHost::version() const
{
    return QStringLiteral(ORBBEC_SETUP_VERSION);
}

QString SetupHost::logPath() const
{
    return m_engine ? m_engine->logPath() : QString();
}

QVariantMap SetupHost::installed() const
{
    return m_env ? m_env->installedInfo() : QVariantMap();
}

void SetupHost::setReleaseSelfTest(bool v)
{
    if (v == m_releaseSelfTest)
        return;
    m_releaseSelfTest = v;
    emit releaseSelfTestChanged();
}

void SetupHost::locatePayload()
{
    // 已打包模式：数据区紧随可执行文件尾部。
    // 读自身所在文件，而不是 argv[0]：rename/copy 后路径可能不同。
    const QString self = QCoreApplication::applicationFilePath();
    QFile f(self);
    if (f.open(QIODevice::ReadOnly)) {
        const qint64 size = f.size();
        if (size > kTrailerSize) {
            f.seek(size - kTrailerSize);
            const QByteArray trailer = f.read(kTrailerSize);
            if (trailer.size() == kTrailerSize && std::memcmp(trailer.constData(), kMagic, 8) == 0) {
                const qint64 payloadOffset = readInt64(trailer, 8);
                const qint64 payloadLength = readInt64(trailer, 16);
                if (payloadOffset > 0 && payloadLength > 0
                    && payloadOffset + payloadLength <= size - kTrailerSize) {
                    m_mode = QStringLiteral("packaged");
                    m_payloadVersion = QString::fromUtf8(trailer.mid(56, 4)).trimmed();
                    f.close();
                    releasePayloadFromSelf();
                    return;
                }
            }
        }
        f.close();
    }

    // 开发模式：--payload 指定的外部安装包。
    const QStringList args = QCoreApplication::arguments();
    for (int i = 1; i < args.size(); ++i) {
        QString p;
        if (args.at(i) == QStringLiteral("--payload") && i + 1 < args.size())
            p = args.at(i + 1);
        else if (args.at(i).startsWith(QStringLiteral("--payload=")))
            p = args.at(i).mid(10);
        if (p.isEmpty())
            continue;
        if (QFileInfo::exists(p)) {
            m_payloadPath = QFileInfo(p).absoluteFilePath();
            m_payloadReady = true;
            m_engine->setPayloadPath(m_payloadPath);
            // 开发模式的版本取自文件名 <产品>-<版本>-<架构>-Installer.exe。
            const QStringList parts = QFileInfo(p).completeBaseName().split(QLatin1Char('-'));
            if (parts.size() >= 3)
                m_payloadVersion = parts.at(1);
        } else {
            m_payloadError = QStringLiteral("指定的安装包不存在：%1").arg(p);
        }
    }
    m_mode = QStringLiteral("development");
    emit payloadPathChanged();
}

void SetupHost::releasePayloadFromSelf()
{
    const QString self = QCoreApplication::applicationFilePath();
    QFile f(self);
    if (!f.open(QIODevice::ReadOnly)) {
        m_payloadError = QStringLiteral("无法读取安装程序自身：%1").arg(self);
        emit payloadPathChanged();
        return;
    }
    const qint64 size = f.size();
    if (!f.seek(size - kTrailerSize)) {
        m_payloadError = QStringLiteral("安装程序尾部数据不完整");
        emit payloadPathChanged();
        return;
    }
    const QByteArray trailer = f.read(kTrailerSize);
    if (trailer.size() != kTrailerSize) {
        m_payloadError = QStringLiteral("安装程序尾部数据不完整");
        emit payloadPathChanged();
        return;
    }
    const qint64 payloadOffset = readInt64(trailer, 8);
    const qint64 payloadLength = readInt64(trailer, 16);
    const QByteArray expectHash = trailer.mid(24, 32);

    // 释放目录按内容位置哈希命名，可跨次复用。
    const QString releaseRoot = QDir(QDir::tempPath()).filePath(QStringLiteral("OrbbecSlicerSetup"));
    const QString hash = QString::fromLatin1(QCryptographicHash::hash(
                                                 QByteArray::number(payloadOffset) + ':' + QByteArray::number(payloadLength),
                                                 QCryptographicHash::Sha256).toHex());
    m_releaseDir = QDir(releaseRoot).filePath(hash.left(16));
    QDir().mkpath(m_releaseDir);
    const QString out = QDir(m_releaseDir).filePath(QStringLiteral("payload-installer.exe"));

    if (!QFileInfo::exists(out) || QFileInfo(out).size() != payloadLength) {
        QFile src(self);
        if (!src.open(QIODevice::ReadOnly)) {
            m_payloadError = QStringLiteral("无法读取负载数据");
            emit payloadPathChanged();
            return;
        }
        src.seek(payloadOffset);
        QFile dst(out);
        if (!dst.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            m_payloadError = QStringLiteral("无法写出负载文件：%1").arg(QDir::toNativeSeparators(out));
            emit payloadPathChanged();
            return;
        }
        QCryptographicHash h(QCryptographicHash::Sha256);
        qint64 remaining = payloadLength;
        while (remaining > 0) {
            const QByteArray chunk = src.read(qMin<qint64>(remaining, 1 << 20));
            if (chunk.isEmpty())
                break;
            h.addData(chunk);
            dst.write(chunk);
            remaining -= chunk.size();
        }
        dst.close();
        if (remaining != 0 || h.result() != expectHash) {
            m_payloadError = QStringLiteral("安装包负载校验失败（可能已损坏）");
            QFile::remove(out);
            emit payloadPathChanged();
            return;
        }
    }

    m_payloadPath = QDir::toNativeSeparators(out);
    m_payloadReady = true;
    m_engine->setPayloadPath(out);
    emit payloadPathChanged();
}

void SetupHost::schedulePayloadCleanup()
{
    // 释放目录按内容位置哈希命名；进程退出时（安装完成或取消）都删掉，
    // 避免 %TEMP% 里长期留一份 200MB 的安装包。文件被占用时删除会失败，忽略即可。
    connect(qApp, &QCoreApplication::aboutToQuit, this, [this] {
        if (!m_releaseDir.isEmpty())
            QDir(m_releaseDir).removeRecursively();
    });
}

QString SetupHost::defaultInstallDir()
{
    return m_env ? m_env->defaultInstallDir() : QString();
}

QString SetupHost::defaultInstallParent()
{
    return m_env ? m_env->defaultInstallParent() : QString();
}

QString SetupHost::installDirForParent(const QString &parent)
{
    return m_env ? m_env->installDirForParent(parent) : QString();
}

QString SetupHost::installParentForDir(const QString &installDir)
{
    return m_env ? m_env->installParentForDir(installDir) : QString();
}

QString SetupHost::probeDirectory(const QString &path)
{
    return m_env ? m_env->probeDirectory(path) : QString();
}

qint64 SetupHost::freeBytes(const QString &path)
{
    return m_env ? m_env->freeBytes(path) : -1;
}

QString SetupHost::normalizeDirPath(const QString &path)
{
    return m_env ? m_env->normalizeDirPath(path) : path.trimmed();
}

void SetupHost::refreshInstalled()
{
    emit installedChanged();
}

bool SetupHost::launchApp(const QString &installDir)
{
    const QString exe = m_env ? m_env->appExecutablePath(installDir) : QString();
    if (exe.isEmpty())
        return false;
    if (!m_env || !m_env->launch(exe))
        return false;
    QCoreApplication::quit();
    return true;
}

bool SetupHost::revealLogs()
{
    return m_env ? m_env->revealDirectory(m_env->logDirectory()) : false;
}

void SetupHost::quit()
{
    QCoreApplication::quit();
}

void SetupHost::setInstallOptions(const QVariantMap &options)
{
    m_installOptions = options;
}

QString SetupHost::toNativePath(const QUrl &url) const
{
    return QDir::toNativeSeparators(url.toLocalFile());
}
