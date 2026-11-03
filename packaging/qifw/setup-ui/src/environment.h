// 安装环境探测：目标目录可写、磁盘剩余空间、已安装版本。
// 全部同步调用且只做只读查询，UI 在启动时与目录变更时各调一次即可。
#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>

struct InstalledInfo {
    bool installed = false;
    QString version;     // 已安装版本（可能为空）
    QString installDir;  // 已安装目录
};

class Environment : public QObject
{
    Q_OBJECT
public:
    explicit Environment(QObject *parent = nullptr);

    // 目录可写：尝试在目录（或其最近存在的祖先）下创建并删除一个临时文件。
    // 返回空串表示可用，否则是可显示给用户的原因（不存在的目录、不是目录、不可写）。
    // 结果按"目录 + 祖先修改时间"缓存，绑定里反复求值不会反复写盘。
    Q_INVOKABLE QString probeDirectory(const QString &path) const;

    // 指定路径所在卷的剩余字节数；无法确定时返回 -1。
    Q_INVOKABLE qint64 freeBytes(const QString &path) const;

    // 安装目录文本的规范化（如 "C:/Program Files/OrbbecSlicer/" → "C:\Program Files\OrbbecSlicer"）：
    // 界面上输入的文本直接作为安装位置时，installDirChanged 要比较规范化后的值。
    Q_INVOKABLE QString normalizeDirPath(const QString &path) const;

    // 默认安装目录：<ProgramFiles>\OrbbecSlicer
    Q_INVOKABLE QString defaultInstallDir() const;

    // 版本来源：优先读注册表，退化到安装目录中的 maintenancetool.exe。
    Q_INVOKABLE QVariantMap installedInfo() const;

    // 安装目录里的主程序名随产品而异（当前是 ob-slicer.exe，历史包是 OrbbecSlicer.exe）。
    // 返回第一个存在的可执行文件；都不存在时返回空串。
    Q_INVOKABLE QString appExecutablePath(const QString &installDir) const;

    // 启动已安装的主程序；成功返回 true。
    Q_INVOKABLE bool launch(const QString &program, const QStringList &args = {}) const;

    // 在文件管理器中打开目录。
    Q_INVOKABLE bool revealDirectory(const QString &path) const;

    Q_INVOKABLE QString logDirectory() const;

private:
    InstalledInfo readInstalled() const;
};
