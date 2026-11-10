// Host object: single entry point exposed to QML (Host).
// Responsibilities: launch mode detection, locating/releasing the payload (QIFW installer package),
// environment query forwarding, log directory, and launch actions.
#pragma once

#include <QObject>
#include <QUrl>
#include <QVariantMap>

class Environment;
class SetupEngine;

class SetupHost : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString mode READ mode CONSTANT)          // packaged | development
    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(QString logPath READ logPath CONSTANT)
    Q_PROPERTY(QString payloadPath READ payloadPath NOTIFY payloadPathChanged)
    Q_PROPERTY(bool payloadReady READ payloadReady NOTIFY payloadPathChanged)
    Q_PROPERTY(QString payloadError READ payloadError NOTIFY payloadPathChanged)
    Q_PROPERTY(QString payloadVersion READ payloadVersion NOTIFY payloadPathChanged)
    Q_PROPERTY(QVariantMap installed READ installed NOTIFY installedChanged)
    Q_PROPERTY(bool releaseSelfTest READ releaseSelfTest WRITE setReleaseSelfTest NOTIFY releaseSelfTestChanged)
    Q_PROPERTY(SetupEngine *engine READ engine CONSTANT)
    // Whether --selftest makes the options page actually run through an "install" (main.cpp reads the env var).
    Q_PROPERTY(bool selfTestOptions READ selfTestOptions CONSTANT)

public:
    explicit SetupHost(Environment *env, QObject *parent = nullptr);
    ~SetupHost() override;

    QString mode() const { return m_mode; }
    QString version() const;
    QString logPath() const;
    QString payloadPath() const { return m_payloadPath; }
    bool payloadReady() const { return m_payloadReady; }
    QString payloadError() const { return m_payloadError; }
    QString payloadVersion() const { return m_payloadVersion; }
    QVariantMap installed() const;
    SetupEngine *engine() const { return m_engine; }
    bool selfTestOptions() const;

    bool releaseSelfTest() const { return m_releaseSelfTest; }
    void setReleaseSelfTest(bool v);

    // Called from QML
    Q_INVOKABLE QString defaultInstallDir();
    Q_INVOKABLE QString defaultInstallParent();
    Q_INVOKABLE QString installDirForParent(const QString &parent);
    Q_INVOKABLE QString installParentForDir(const QString &installDir);
    Q_INVOKABLE QString probeDirectory(const QString &path);
    Q_INVOKABLE qint64 freeBytes(const QString &path);
    Q_INVOKABLE QString normalizeDirPath(const QString &path);
    Q_INVOKABLE void refreshInstalled();
    Q_INVOKABLE bool launchApp(const QString &installDir);
    Q_INVOKABLE bool revealLogs();
    Q_INVOKABLE void quit();

    // Install options (shortcut/file association/launch after completion) are not passed into
    // QIFW component scripts; after install completes the engine creates the shortcut and
    // registers the file association itself based on the target directory (see
    // SetupEngine::applyInstallOptions); launching the software is still decided by the
    // finish page's "Launch now". Recorded here only.
    Q_INVOKABLE void setInstallOptions(const QVariantMap &options);
    Q_INVOKABLE QVariantMap installOptions() const { return m_installOptions; }

    // Convert a QML url to a local path (the file chooser returns file:///...).
    Q_INVOKABLE QString toNativePath(const QUrl &url) const;

signals:
    void payloadPathChanged();
    void installedChanged();
    void releaseSelfTestChanged();

private:
    // Read the data area index at our own tail; use it if found, otherwise it is development mode (needs --payload).
    void locatePayload();
    void releasePayloadFromSelf();
    void schedulePayloadCleanup();

    Environment *m_env = nullptr;
    SetupEngine *m_engine = nullptr;
    QString m_mode = QStringLiteral("development");
    QString m_payloadPath;
    QString m_payloadError;
    QString m_payloadVersion;
    QVariantMap m_installOptions;
    QString m_releaseDir;
    bool m_payloadReady = false;
    bool m_releaseSelfTest = false;
};
