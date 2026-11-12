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
// Index of the data area appended to the end of the PE (see design.md D3 and tasks 7.1):
//   [payload bytes][magic 8B "OSUI1"][offset 8B][length 8B][sha256 32B][version 4B]
// All little-endian; the 4 bytes after magic are reserved, matching "magic OSUI1" in the task spec.
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
    // The self-contained uninstaller source file is passed in by the Setup.exe launcher after
    // extraction (deployed after a successful install).
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
    // The full payload version ships with the UI (see package-setup.ps1): the trailer field is only 4 bytes,
    // and the extracted payload file is always named "installer.exe", so neither can tell us "0.4.0-beta.1".
    // Without this the packaged flow reported an empty target version and called every install a downgrade.
    const QString bundledVersion = bundledPayloadVersion();
    // Packaged mode: the data area immediately follows the executable's tail.
    // Read the file the executable itself lives in, not argv[0]: the path may differ after rename/copy.
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
                    // Fall back to the (possibly truncated) trailer for packages built before version.txt existed.
                    m_payloadVersion = bundledVersion;
                    if (m_payloadVersion.isEmpty())
                        m_payloadVersion = QString::fromUtf8(trailer.mid(56, 4)).trimmed();
                    f.close();
                    releasePayloadFromSelf();
                    return;
                }
            }
        }
        f.close();
    }

    // Development mode: external installer package specified by --payload.
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
            // The launcher extracts the package as payload/installer.exe, so a bundled version wins; a hand-run
            // package still falls back to <product>-<version>-<arch>-Installer.exe.
            if (!bundledVersion.isEmpty()) {
                m_payloadVersion = bundledVersion;
            } else {
                const QStringList parts = QFileInfo(p).completeBaseName().split(QLatin1Char('-'));
                if (parts.size() >= 3)
                    m_payloadVersion = parts.at(1);
            }
        } else {
            m_payloadError = tr("The specified installer package does not exist: %1").arg(p);
        }
    }
    m_mode = QStringLiteral("development");
    emit payloadPathChanged();
}

QString SetupHost::bundledPayloadVersion() const
{
    // package-setup.ps1 writes ui/version.txt with the full payload version: the 4-byte trailer field
    // cannot hold a prerelease tag, and a truncated "0.4." made the maintenance screen classify a
    // re-install of 0.4.0-beta.1 as a downgrade.
    QFile file(QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("version.txt")));
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return QString();
    return QString::fromUtf8(file.readAll()).trimmed();
}

void SetupHost::releasePayloadFromSelf()
{
    const QString self = QCoreApplication::applicationFilePath();
    QFile f(self);
    if (!f.open(QIODevice::ReadOnly)) {
        m_payloadError = tr("Cannot read the installer itself: %1").arg(self);
        emit payloadPathChanged();
        return;
    }
    const qint64 size = f.size();
    if (!f.seek(size - kTrailerSize)) {
        m_payloadError = tr("The installer trailer data is incomplete");
        emit payloadPathChanged();
        return;
    }
    const QByteArray trailer = f.read(kTrailerSize);
    if (trailer.size() != kTrailerSize) {
        m_payloadError = tr("The installer trailer data is incomplete");
        emit payloadPathChanged();
        return;
    }
    const qint64 payloadOffset = readInt64(trailer, 8);
    const qint64 payloadLength = readInt64(trailer, 16);
    const QByteArray expectHash = trailer.mid(24, 32);

    // The release directory is named by a hash of the content position, reusable across runs.
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
            m_payloadError = tr("Cannot read payload data");
            emit payloadPathChanged();
            return;
        }
        src.seek(payloadOffset);
        QFile dst(out);
        if (!dst.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            m_payloadError = tr("Cannot write the payload file: %1").arg(QDir::toNativeSeparators(out));
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
            m_payloadError = tr("Installer package payload verification failed (possibly corrupted)");
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
    // The release directory is named by a hash of the content position; delete it when the
    // process exits (install complete or cancelled), avoiding a 200MB installer package
    // lingering in %TEMP%. Deletion fails if the file is in use; ignore that.
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

QString SetupHost::userDataDirectory(bool roaming)
{
    return m_env ? m_env->userDataDirectory(roaming) : QString();
}

qint64 SetupHost::directoryBytes(const QString &path)
{
    return m_env ? m_env->directoryBytes(path) : 0;
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
