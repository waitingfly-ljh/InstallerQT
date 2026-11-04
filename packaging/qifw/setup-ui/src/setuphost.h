// 宿主对象：给 QML 暴露的单一入口（Host）。
// 负责：启动模式判定、负载（QIFW 安装包）的定位/释放、环境查询转发、日志目录与启动动作。
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
    // --selftest 时是否让设置页真的走一遍"安装"（main.cpp 读环境变量）。
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

    // QML 调用
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

    // 安装选项（快捷方式/文件关联/完成后启动）不带入 QIFW 组件脚本，由引擎在安装完成后
    // 按目标目录自己创建快捷方式与注册文件关联（见 SetupEngine::applyInstallOptions）；
    // 启动软件仍由完成页的"立即启动"决定。这里只记录。
    Q_INVOKABLE void setInstallOptions(const QVariantMap &options);
    Q_INVOKABLE QVariantMap installOptions() const { return m_installOptions; }

    // QML 的 url 转成本地路径（文件选择对话框返回 file:///...）。
    Q_INVOKABLE QString toNativePath(const QUrl &url) const;

signals:
    void payloadPathChanged();
    void installedChanged();
    void releaseSelfTestChanged();

private:
    // 读取自身尾部的数据区索引；找到就用，找不到说明是开发模式（需 --payload）。
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
