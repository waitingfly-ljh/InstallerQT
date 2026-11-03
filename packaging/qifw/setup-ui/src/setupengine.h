// 安装引擎：把 QIFW 的静默安装 / 卸载作为子进程运行，向 QML 暴露
// 统一的任务生命周期（start -> progress* -> finished）与日志落盘。
//
// 成功/失败只以退出码判定；stdout/stderr 只用于展示与诊断。
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
    Q_PROPERTY(QString detail READ detail NOTIFY detailChanged)
    Q_PROPERTY(QString logPath READ logPath NOTIFY logPathChanged)

public:
    explicit SetupEngine(Environment *env, QObject *parent = nullptr);
    ~SetupEngine() override;

    bool busy() const { return m_busy; }
    int progress() const { return m_progress; }
    QString phase() const { return m_phase; }
    QString detail() const { return m_detail; }
    QString logPath() const { return m_logPath; }

    // overwrite=false 且目标目录已有内容时，引擎追加 -x 强制覆盖（QIFW 默认拒绝）。
    Q_INVOKABLE void startInstall(const QString &targetDir, const QVariantMap &options);
    Q_INVOKABLE void startUninstall(const QString &installDir, bool removeAllData, bool keepDataDir);
    Q_INVOKABLE void cancel();

    // 安装包路径：已打包模式由 SetupHost 从自身尾部数据区释放；开发模式来自 --payload。
    void setPayloadPath(const QString &path) { m_payloadPath = path; }
    // Setup.exe 启动器解压出来的自包含卸载器（安装成功后部署到用户目录）。
    void setUninstallerPath(const QString &path) { m_uninstallerSource = path; }
    void setLogPath(const QString &path);

signals:
    void busyChanged();
    void progressChanged();
    void phaseChanged();
    void detailChanged();
    void logPathChanged();
    void finished(int exitCode, const QString &summary);
    void cancelled();

private:
    void startProcess(const QString &program, const QStringList &args, const QString &phase);
    void onReadyRead();
    void onFinished(int exitCode, QProcess::ExitStatus status);
    void advancePhaseFromLine(const QString &line);
    void applyInstallOptions();
    bool createShortcut(const QString &lnkPath, const QString &target, const QString &workDir);
    bool createShellLink(const QString &lnkPath, const QString &target, const QString &args,
                         const QString &workDir);
    // 安装/维护成功后：部署品牌化卸载器、改写系统卸载登记与开始菜单快捷方式。
    void installUninstaller();
    // 卸载完成后：删除开始菜单快捷方式、自建的卸载登记与 Uninstaller 值。
    void removeUninstallerRegistration();
    void cleanupUserDataIfRequested();
    void appendLog(const QString &line);
    QString makeLogPath() const;
    void setProgress(int value);
    // 维护（修复/升级/降级）：QIFW 拒绝覆盖已安装目录。先把旧目录改名备份，
    // 安装失败/取消时恢复，成功后删除备份。
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
    QString m_selfUninstallKey;   // 自建的卸载登记键（QIFW 的键由 pr 自己删）
    QString m_cacheDir;
    QString m_installDir;
    QString m_logPath;
    QString m_phase;
    QString m_detail;
    QString m_pendingLine;
    QString m_backupDir;      // 维护时旧安装目录的临时备份（空 = 不是覆盖安装）
    int m_progress = 0;
    bool m_busy = false;
    bool m_cancelRequested = false;
    bool m_uninstallMode = false;
    bool m_targetExisted = false;   // 安装前目标目录是否已存在（取消时决定能否整目录删除）
    bool m_removeAllData = false;
    bool m_keepDataDir = false;
    // 安装选项：QIFW 包本身不处理，安装成功后由 applyInstallOptions() 落实。
    bool m_shortcutDesktop = false;
    bool m_assoc3mf = false;
    bool m_assocStl = false;
    // "安装完成后启动"：完成页"立即启动"的默认动作看它（Main.qml），这里只保存选择。
    bool m_launchAfterInstall = false;
};
