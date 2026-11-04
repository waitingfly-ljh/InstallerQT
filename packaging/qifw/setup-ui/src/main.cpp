// 安装器外壳入口。
// 职责只有三件：解析自己的命令行、决定"开发模式 / 已打包模式"、把宿主对象交给 QML。
// 界面逻辑在根目录 QML 与 pages/ 下，安装/卸载的进程管理在 setupengine.cpp。
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QCommandLineParser>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJSValue>
#include <QQuickWindow>
#include <QStandardPaths>
#include <QWindow>
#include <QTimer>
#include <QDebug>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

#ifdef ORBBEC_SETUP_SHOT
#include <QImage>
#include <QQmlEngine>
#include <QQmlPropertyMap>
#include <QScreen>
#include <QWindow>
#endif

#include "setuphost.h"
#include "setupengine.h"
#include "environment.h"

namespace {

// 外壳启动模式：由命令行决定，QML 据此选择首屏。
enum class StartMode { Normal, SelfTest, Help };

struct LaunchPlan {
    StartMode mode = StartMode::Normal;
    bool silentInstall = false;
    bool silentUninstall = false;
    QString targetDir;
    QString payloadPath;
    QString logPath;
    // --uninstall / --install-dir：系统卸载入口与自包含卸载器使用。
    bool uninstall = false;
    QString installDirOverride;
    // --uninstaller <path>：Setup.exe 启动器解压出来的卸载器源文件（安装成功后部署）。
    QString uninstallerPath;
    // 是否出现 --silent（其后参数透传给引擎）。
    bool silent = false;
    // --selftest --qml-smoke [--view <name>] [--option <key>] [--dir <路径>]
    bool qmlSmoke = false;
    QString smokeView;
    int smokeOption = 0;
    QString smokeDir;
    // --selftest --check-options [--dir <路径>]：只做目录/空间断言，不启动安装。
    bool checkOptions = false;
    // 自检扩展：--check-steps 验证侧栏步骤状态；--check-launch <目录> 验证启动主程序。
    bool checkSteps = false;
    bool checkWindow = false;
    QString checkLaunchDir;
    QString checkShortcutDir;
    bool checkFinishTiming = false;
    bool checkRunMode = false;
    // 测试钩子：静默安装时使用安装设置页的默认选项（快捷方式/.3mf/完成后启动），
    // 供打包回路验证"安装选项在卸载时被还原"。
    bool withOptions = false;
};

LaunchPlan parseArgs(QGuiApplication &app)
{
    LaunchPlan plan;
    const QStringList args = app.arguments();

    // --silent 之后的参数（in -t <dir> / pr ...）原样透传给引擎；也支持 `--` 分隔。
    QStringList own;
    QStringList passthrough;
    bool afterSeparator = false;
    for (int i = 1; i < args.size(); ++i) {
        const QString a = args.at(i);
        if (!afterSeparator && (a == QStringLiteral("--silent") || a == QStringLiteral("--"))) {
            plan.silent = true;
            afterSeparator = true;
            continue;
        }
        if (afterSeparator)
            passthrough << a;
        else
            own << a;
    }

    for (int i = 0; i < own.size(); ++i) {
        const QString a = own.at(i);
        if (a == QStringLiteral("--selftest")) {
            plan.mode = StartMode::SelfTest;
        } else if (a == QStringLiteral("--payload") && i + 1 < own.size()) {
            plan.payloadPath = own.at(++i);
        } else if (a.startsWith(QStringLiteral("--payload="))) {
            plan.payloadPath = a.mid(10);
        } else if (a == QStringLiteral("--log") && i + 1 < own.size()) {
            plan.logPath = own.at(++i);
        } else if (a.startsWith(QStringLiteral("--log="))) {
            plan.logPath = a.mid(6);
        } else if (a == QStringLiteral("--qml-smoke")) {
            plan.qmlSmoke = true;
        } else if (a == QStringLiteral("--check-options")) {
            plan.checkOptions = true;
        } else if (a == QStringLiteral("--check-steps")) {
            plan.checkSteps = true;
        } else if (a == QStringLiteral("--check-window")) {
            plan.checkWindow = true;
        } else if (a == QStringLiteral("--uninstall")) {
            plan.uninstall = true;
        } else if (a == QStringLiteral("--install-dir") && i + 1 < own.size()) {
            plan.installDirOverride = own.at(++i);
        } else if (a == QStringLiteral("--uninstaller") && i + 1 < own.size()) {
            plan.uninstallerPath = own.at(++i);
        } else if (a == QStringLiteral("--check-launch") && i + 1 < own.size()) {
            plan.checkLaunchDir = own.at(++i);
        } else if (a == QStringLiteral("--check-desktop-shortcut") && i + 1 < own.size()) {
            plan.checkShortcutDir = own.at(++i);
        } else if (a == QStringLiteral("--check-finish-timing")) {
            plan.checkFinishTiming = true;
        } else if (a == QStringLiteral("--check-run-mode")) {
            plan.checkRunMode = true;
        } else if (a == QStringLiteral("--with-options")) {
            plan.withOptions = true;
        } else if (a == QStringLiteral("--view") && i + 1 < own.size()) {
            plan.smokeView = own.at(++i);
        } else if (a == QStringLiteral("--dir") && i + 1 < own.size()) {
            plan.smokeDir = own.at(++i);
        } else if (a == QStringLiteral("--option") && i + 1 < own.size()) {
            static const QStringList keys = { QStringLiteral("shortcutDesktop"), QStringLiteral("assoc3mf"),
                                              QStringLiteral("assocStl"), QStringLiteral("launchAfterInstall") };
            const int k = keys.indexOf(own.at(i + 1));
            ++i;
            plan.smokeOption = qMax(0, k);
        }
    }

    plan.silentInstall = passthrough.contains(QStringLiteral("in"))
                         || passthrough.contains(QStringLiteral("install"));
    plan.silentUninstall = passthrough.contains(QStringLiteral("pr"))
                           || passthrough.contains(QStringLiteral("purge"));
    const int t = passthrough.indexOf(QStringLiteral("-t"));
    if (t >= 0 && t + 1 < passthrough.size())
        plan.targetDir = passthrough.at(t + 1);
    return plan;
}

// 截图模式（仅 -DORBBEC_SETUP_SHOT）：把控制器摆到某个视图。
// 视图名与 SetupController.view 一致；uninstall-* 同时把侧栏切成卸载步骤。
QVariantMap shotModelFor(const QString &name)
{
    QVariantMap m;
    if (name == QLatin1String("uninstall-scope")) {
        m.insert(QStringLiteral("uninstalling"), true);
        m.insert(QStringLiteral("view"), QStringLiteral("dataScope"));
    } else if (name == QLatin1String("uninstall-confirm")) {
        m.insert(QStringLiteral("uninstalling"), true);
        m.insert(QStringLiteral("view"), QStringLiteral("confirm"));
    } else if (name == QLatin1String("uninstall-done")) {
        m.insert(QStringLiteral("uninstalling"), true);
        m.insert(QStringLiteral("view"), QStringLiteral("uninstalled"));
    } else if (!name.isEmpty()) {
        m.insert(QStringLiteral("view"), name);
    }
    return m;
}

#ifdef ORBBEC_SETUP_SHOT
// 截图单例：QML 往 capture 键写路径，窗口显示后抓一张 PNG 再退出。
QObject *makeShotCapture(QQmlEngine *engine, QJSEngine *js)
{
    Q_UNUSED(js)
    auto *map = new QQmlPropertyMap(engine);
    QObject::connect(map, &QQmlPropertyMap::valueChanged, engine,
                     [map](const QString &key, const QVariant &value) {
                         if (key != QLatin1String("capture"))
                             return;
                         const QString path = value.toString();
                         qInfo().noquote() << "截图请求:" << path;
                         QTimer::singleShot(1500, map, [path]() {
                             bool saved = false;
                             for (QWindow *win : QGuiApplication::topLevelWindows()) {
                                 if (!win->isVisible())
                                     continue;
                                 // 窗口可能还没完成第一次合成（isExposed() 为假），
                                 // 这时 grabWindow(winId) 抓到的是背景/黑块；改为自己重绘整窗。
                                 auto *quick = qobject_cast<QQuickWindow *>(win);
                                 if (quick && !win->isExposed())
                                     saved = quick->grabWindow().save(path, "PNG");
                                 else
                                     saved = win->screen()->grabWindow(win->winId()).save(path, "PNG");
                                 qInfo().noquote() << "截图已保存:" << path << saved;
                                 break;
                             }
                             QCoreApplication::quit();
                         });
                     });
    return map;
}
#endif

// 自检：把选项页摆到指定目录，读按钮可用性与原因，必要时真的点一次"安装"。
void runSelftestDrive(QQmlApplicationEngine &qml, SetupHost &host, const LaunchPlan &plan, bool checkOnly)
{
    QObject *root = qml.rootObjects().value(0);
    if (!root) {
        qCritical().noquote() << "SELFTEST 根对象为空";
        QCoreApplication::exit(2);
        return;
    }

    QObject *ctl = root->property("ctl").value<QObject *>();
    if (!ctl) {
        for (QObject *o : root->findChildren<QObject *>()) {
            if (QString::fromLatin1(o->metaObject()->className()).contains(QStringLiteral("SetupController"))) {
                ctl = o;
                break;
            }
        }
    }
    QObject *options = ctl ? ctl->property("installOptions").value<QObject *>() : nullptr;
    if (options && !plan.smokeDir.isEmpty()) {
        // --dir 传的是"父文件夹"（与界面语义一致），最终目录由宿主按同一规则拼出。
        options->setProperty("installParentDir", plan.smokeDir);
        options->setProperty("installDir", host.installDirForParent(plan.smokeDir));
    }

    QObject *page = root->findChild<QObject *>(QStringLiteral("optionsPage"));
    if (!page) {
        qCritical().noquote() << "SELFTEST 未找到 optionsPage";
        QCoreApplication::exit(2);
        return;
    }

    const bool canInstall = page->property("canInstall").toBool();
    const QString problem = page->property("dirProblem").toString();
    const QString dir = page->property("installParentDir").toString();
    // 父文件夹 → 最终安装目录：--check-options 用它断言拼接规则（不需要真的安装）。
    const QString effectiveDir = page->property("effectiveInstallDir").toString();
    qInfo().noquote() << QStringLiteral("SELFTEST 位置=[%1] 安装到=[%2] 按钮可用=%3 提示=%4")
                             .arg(QDir::toNativeSeparators(dir), QDir::toNativeSeparators(effectiveDir))
                             .arg(canInstall ? QStringLiteral("true") : QStringLiteral("false"), problem);
    qInfo().noquote() << QStringLiteral("SELFTEST 目录检查完成: %1 视图=%2")
                             .arg(QString::fromLatin1(root->metaObject()->className()),
                                  ctl ? ctl->property("view").toString() : QStringLiteral("?"));
    if (ctl) {
        const QVariantMap installed = ctl->property("installed").toMap();
        qInfo().noquote() << QStringLiteral("SELFTEST 已安装: installed=%1 version=%2 dir=%3 目标版本=%4 模式=%5")
                                 .arg(installed.value(QStringLiteral("installed")).toBool() ? QStringLiteral("true")
                                                                                            : QStringLiteral("false"),
                                      installed.value(QStringLiteral("version")).toString(),
                                      QDir::toNativeSeparators(installed.value(QStringLiteral("installDir")).toString()),
                                      ctl->property("targetVersion").toString(),
                                      ctl->property("mode").toString());
    }

    if (checkOnly) {
        QCoreApplication::exit(0);
        return;
    }

    if (plan.checkSteps) {
        // 3.6：设置 → 过程 → 完成 推进时，侧栏三步必须是 active/done/pending 的确定组合。
        struct Case { const char *view; const char *expect; };
        const Case cases[] = {
            {"options", "active,pending,pending"},
            {"progress", "done,active,pending"},
            {"complete", "done,done,active"},
        };
        bool ok = true;
        for (const Case &c : cases) {
            ctl->setProperty("view", QString::fromLatin1(c.view));
            const QVariant v = ctl->property("installSteps");
            const QVariantList list = v.value<QJSValue>().toVariant().toList();
            QStringList states;
            for (const QVariant &item : list)
                states << item.toMap().value(QStringLiteral("state")).toString();
            const QString actual = states.join(QLatin1Char(','));
            const QString expect = QString::fromLatin1(c.expect);
            qInfo().noquote() << QStringLiteral("SELFTEST 步骤 %1: %2（期望 %3）")
                                     .arg(QString::fromLatin1(c.view), actual, expect);
            if (actual != expect)
                ok = false;
        }
        QCoreApplication::exit(ok ? 0 : 2);
        return;
    }

    const auto flag = [options](const char *key) {
        return options && options->property(key).toBool();
    };
    qInfo().noquote() << QStringLiteral("自检: 交给引擎 目录=[%1] 快捷方式=%2 .3mf=%3 .stl=%4 完成后启动=%5")
                             .arg(QDir::toNativeSeparators(dir))
                             .arg(flag("shortcutDesktop") ? 1 : 0)
                             .arg(flag("assoc3mf") ? 1 : 0)
                             .arg(flag("assocStl") ? 1 : 0)
                             .arg(flag("launchAfterInstall") ? 1 : 0);

    QObject::connect(host.engine(), &SetupEngine::finished, &qml,
                     [](int code, const QString &summary) {
                         qInfo().noquote() << QStringLiteral("SELFTEST 命中安装按钮：引擎收到 %1 %2")
                                                  .arg(code)
                                                  .arg(summary);
                         // 引擎的 finished 在 QML 槽里同步发出，延到下一轮再退出，
                         // 让控制器先把视图切到进度/失败页。
                         QTimer::singleShot(0, qApp, []() { QCoreApplication::exit(0); });
                     });
    // 兜底：引擎没立刻结束时也要退出（例如负载存在、安装真的跑起来）。
    QTimer::singleShot(50, qApp, []() { QCoreApplication::exit(0); });
    QMetaObject::invokeMethod(page, "installRequested", Qt::DirectConnection);
}

} // namespace

// 无边框窗口（Qt.FramelessWindowHint）让 Qt 不设 WS_MINIMIZEBOX，Windows 因此不把
// 任务栏按钮点击翻译成最小化。这里补上该样式位，恢复"点任务栏最小化、再点还原"的
// 原生行为；不加 WS_MAXIMIZEBOX —— 产品不允许最大化，加了会引入多余的系统手势。
// 自绘标题栏的 showMinimized() 走 Qt 的窗口状态接口，与本样式位无关，不受影响。
static void restoreTaskbarMinimize(QQuickWindow *window)
{
    if (!window)
        return;
#ifdef Q_OS_WIN
    // winId() 在原生窗口尚未创建时会立即创建它；QML 里 visible: true 时通常已存在。
    const HWND hwnd = reinterpret_cast<HWND>(window->winId());
    if (!hwnd)
        return;
    const LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
    if (style & WS_MINIMIZEBOX)
        return;
    SetWindowLongPtrW(hwnd, GWL_STYLE, style | WS_MINIMIZEBOX);
#else
    Q_UNUSED(window)
#endif
}

// 对当前所有顶层 QQuickWindow 补样式位。窗口不是 QML 根对象（App.qml 的根是 Item，
// 窗口是内部的 ApplicationWindow），所以按 topLevelWindows() 找，而不是 rootObjects()。
// 只处理一次：打标记后不再重复；之后连接 visibilityChanged，覆盖 Qt 在显示/状态切换时
// 重新设置窗口样式的情况。
static void applyTaskbarMinimizeToWindows()
{
#ifdef Q_OS_WIN
    static const char *kHooked = "_orbbecTaskbarMinimizeHooked";
    const auto windows = QGuiApplication::topLevelWindows();
    for (QWindow *w : windows) {
        auto *qw = qobject_cast<QQuickWindow *>(w);
        if (!qw || qw->property(kHooked).toBool())
            continue;
        qw->setProperty(kHooked, true);
        restoreTaskbarMinimize(qw);
        QObject::connect(qw, &QWindow::visibilityChanged, qw,
                         [qw]() { restoreTaskbarMinimize(qw); });
        qInfo().noquote() << QStringLiteral("任务栏最小化: 已为窗口补 WS_MINIMIZEBOX");
    }
#endif
}

int main(int argc, char *argv[])
{
    // --selftest 用最小平台运行：无窗口也要能完成 QML 加载。
    // 例外：要出截图（ORBBEC_SETUP_SHOT_DIR 非空）时必须开真窗口，否则抓不到像素。
    const bool wantShot = !qEnvironmentVariableIsEmpty("ORBBEC_SETUP_SHOT_DIR");
    bool wantWindowCheck = false;
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--check-window") == 0)
            wantWindowCheck = true;
    }
    if (argc > 1 && !wantShot && !wantWindowCheck) {
        for (int i = 1; i < argc; ++i) {
            if (qstrcmp(argv[i], "--selftest") == 0 && !qEnvironmentVariableIsSet("QT_QPA_PLATFORM")) {
                qputenv("QT_QPA_PLATFORM", "minimal");
                break;
            }
        }
    }

    QGuiApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("OrbbecSlicerSetup"));
    QCoreApplication::setOrganizationName(QStringLiteral("Orbbec"));
    QCoreApplication::setApplicationVersion(QStringLiteral(ORBBEC_SETUP_VERSION));
    // 窗口/任务栏图标：与嵌入到 exe 的品牌图标一致。
    QGuiApplication::setWindowIcon(QIcon(QStringLiteral(":/app.ico")));

    const LaunchPlan plan = parseArgs(app);

    // WIN32 子系统没有控制台：诊断信息写进 %LOCALAPPDATA%\Orbbec\OrbbecSlicerSetup\logs\setup-shell.log，
    // --selftest / 截图脚本从这里读失败原因。
    const QString logDir = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
                           + QStringLiteral("/logs");
    QDir().mkpath(logDir);
    static QFile diagLog(logDir + QStringLiteral("/setup-shell.log"));
    diagLog.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text);
    qInstallMessageHandler([](QtMsgType type, const QMessageLogContext &ctx, const QString &msg) {
        Q_UNUSED(ctx)
        if (diagLog.isOpen()) {
            diagLog.write(QStringLiteral("[%1] %2\n").arg(int(type)).arg(msg).toUtf8());
            diagLog.flush();
        }
    });


    Environment env;
    SetupHost host(&env);
    if (!plan.logPath.isEmpty())
        host.engine()->setLogPath(plan.logPath);

    // 静默模式：不加载界面，退出码即结果。
    if (plan.silent || plan.silentInstall || plan.silentUninstall) {
        // 有些失败/快速路径会在进入事件循环前同步 emit finished；记下来直接返回，
        // 否则 exit() 早于 exec() 会被忽略，进程永远不退出。
        int earlyExit = -1;
        QObject::connect(host.engine(), &SetupEngine::finished, &app,
                         [&earlyExit](int code, const QString &) {
                             earlyExit = code;
                             QCoreApplication::exit(code);
                         });
        QObject::connect(host.engine(), &SetupEngine::cancelled, &app,
                         [&earlyExit]() {
                             earlyExit = 1;
                             QCoreApplication::exit(1);
                         });
        // 验证取消路径用：ORBBEC_SETUP_SELFTEST_CANCEL_MS=300 时，300ms 后请求取消。
        const int cancelMs = qEnvironmentVariableIntValue("ORBBEC_SETUP_SELFTEST_CANCEL_MS");
        if (cancelMs > 0) {
            QTimer::singleShot(cancelMs, host.engine(), [&host]() { host.engine()->cancel(); });
        }
        const bool uninstall = plan.silentUninstall || plan.uninstall;
        if (uninstall) {
            QString dir = plan.targetDir;
            if (!plan.installDirOverride.isEmpty())
                dir = plan.installDirOverride;
            if (dir.isEmpty())
                dir = host.installed().value(QStringLiteral("installDir")).toString();
            // 测试钩子：静默卸载没有界面可勾选"保留用户数据文件夹"，用环境变量打开它，
            // 让打包回路能验证"保留用户数据目录"与"安装目录整体删除"互不影响。
            const bool keepDataDir = !qEnvironmentVariableIsEmpty("ORBBEC_SETUP_SELFTEST_KEEP_DATA_DIR");
            host.engine()->startUninstall(dir, false, keepDataDir);
        } else {
            QVariantMap options;
            if (plan.withOptions) {
                options.insert(QStringLiteral("shortcutDesktop"), true);
                options.insert(QStringLiteral("assoc3mf"), true);
                options.insert(QStringLiteral("assocStl"), false);
                options.insert(QStringLiteral("launchAfterInstall"), true);
            }
            host.engine()->startInstall(plan.targetDir, options);
        }
        if (earlyExit >= 0)
            return earlyExit;
        return app.exec();
    }


    // --selftest --check-desktop-shortcut <目录>：验证能在桌面创建指向主程序的快捷方式。
    if (plan.mode == StartMode::SelfTest && !plan.checkShortcutDir.isEmpty()) {
        const bool created = host.engine()->ensureDesktopShortcut(plan.checkShortcutDir);
        const QString lnk = QDir(QStandardPaths::writableLocation(QStandardPaths::DesktopLocation))
                                .filePath(QStringLiteral("OrbbecSlicer.lnk"));
        const bool exists = QFileInfo::exists(lnk);
        qInfo().noquote() << QStringLiteral("SELFTEST 桌面快捷方式: 创建=%1 存在=%2 路径=%3")
                                 .arg(created ? QStringLiteral("true") : QStringLiteral("false"),
                                      exists ? QStringLiteral("true") : QStringLiteral("false"),
                                      QDir::toNativeSeparators(lnk));
        return (created && exists) ? 0 : 2;
    }

    // --selftest --check-launch <目录>：验证"立即启动"能拉起安装目录里的主程序。
    if (plan.mode == StartMode::SelfTest && !plan.checkLaunchDir.isEmpty()) {
        const bool ok = host.launchApp(plan.checkLaunchDir);
        qInfo().noquote() << QStringLiteral("SELFTEST 启动主程序: %1 目录=%2")
                                 .arg(ok ? QStringLiteral("true") : QStringLiteral("false"),
                                      QDir::toNativeSeparators(plan.checkLaunchDir));
        return ok ? 0 : 2;
    }

    QQmlApplicationEngine qml(qApp);
    QObject::connect(&qml, &QQmlApplicationEngine::warnings, &app, [](const QList<QQmlError> &errs) {
        for (const QQmlError &e : errs)
            qCritical().noquote() << "QML 警告" << e.url().toString() << e.line() << e.description();
    });

    bool qmlFailed = false;
    QObject::connect(&qml, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [&qmlFailed](const QUrl &url) {
                         qmlFailed = true;
                         qCritical().noquote() << "QML 加载失败:" << url.toString();
                     });

#ifdef ORBBEC_SETUP_SHOT
    qmlRegisterSingletonType<QQmlPropertyMap>("OrbbecShot", 1, 0, "QmlShot", makeShotCapture);
    const QString shotView = plan.smokeView.isEmpty() ? qEnvironmentVariable("ORBBEC_SETUP_SHOT")
                                                      : plan.smokeView;
    qml.rootContext()->setContextProperty(QStringLiteral("shotModel"), shotModelFor(shotView));
#else
    if (plan.qmlSmoke) {
        qCritical().noquote() << "--qml-smoke 只在截图构建（-DORBBEC_SETUP_SHOT=ON）里可用";
        return 2;
    }
#endif

    const QString shotDir = qEnvironmentVariable("ORBBEC_SETUP_SHOT_DIR");
    qml.rootContext()->setContextProperty(QStringLiteral("viewNameGlobal"), plan.smokeView);
    qml.rootContext()->setContextProperty(QStringLiteral("shotDirGlobal"), shotDir);
    qml.rootContext()->setContextProperty(QStringLiteral("smokeView"), shotModelFor(plan.smokeView));
    qml.rootContext()->setContextProperty(QStringLiteral("smokeOption"), plan.smokeOption);
    qml.rootContext()->setContextProperty(QStringLiteral("smokeDir"), plan.smokeDir);
    qml.rootContext()->setContextProperty(QStringLiteral("uninstallMode"), plan.uninstall);
    qml.rootContext()->setContextProperty(QStringLiteral("installDirPath"), plan.installDirOverride);
    qml.rootContext()->setContextProperty(QStringLiteral("Host"), &host);
    qml.rootContext()->setContextProperty(QStringLiteral("SetupEngine"), host.engine());

    const bool driveOptions = plan.mode == StartMode::SelfTest
                              && (plan.checkOptions || plan.checkSteps || host.selfTestOptions());
    const QString entry = (plan.mode == StartMode::SelfTest && !driveOptions && !plan.qmlSmoke
                           && !plan.checkWindow && !plan.checkFinishTiming && !plan.checkRunMode)
                              ? QStringLiteral("LoadEntry")
                              : QStringLiteral("App");
    qml.load(QUrl(QStringLiteral("qrc:/SetupUi/%1.qml").arg(entry)));

    if (qmlFailed)
        return 2;

    // 任务栏最小化：窗口是 QML 内部创建的 ApplicationWindow，创建时机晚于 load 返回，
    // 且 Qt 在显示/状态切换时可能重设样式。按几个时间点扫描一次，命中即打标记并与
    // visibilityChanged 连接，之后由窗口自己维护。
    for (int delayMs : {0, 50, 200, 500, 1200}) {
        QTimer::singleShot(delayMs, &app, []() { applyTaskbarMinimizeToWindows(); });
    }

    if (plan.checkRunMode) {
        // 验证"完成页用的是点击安装时固化的 runMode"，而不是安装后重算的 mode。
        QTimer::singleShot(100, &app, [&qml]() {
            QObject *root = qml.rootObjects().value(0);
            QObject *ctl = root ? root->property("ctl").value<QObject *>() : nullptr;
            if (!ctl) { qCritical() << "SELFTEST 未找到 controller"; QCoreApplication::exit(2); return; }
            ctl->setProperty("targetVersion", QStringLiteral("1.0.0"));
            const auto check = [ctl](bool installed, const QString &version, const QString &expect) {
                QVariantMap m;
                m.insert(QStringLiteral("installed"), installed);
                m.insert(QStringLiteral("version"), version);
                m.insert(QStringLiteral("installDir"), installed ? QStringLiteral("X") : QString());
                ctl->setProperty("installed", m);
                QMetaObject::invokeMethod(ctl, "beginInstall", Qt::DirectConnection);
                const QString got = ctl->property("runMode").toString();
                qInfo().noquote() << QStringLiteral("SELFTEST runMode installed=%1 version=%2 got=%3 expect=%4")
                                         .arg(installed ? 1 : 0).arg(version, got, expect);
                return got == expect;
            };
            bool ok = true;
            ok = check(false, QString(), QStringLiteral("fresh")) && ok;
            ok = check(true, QStringLiteral("1.0.0"), QStringLiteral("repair")) && ok;
            ok = check(true, QStringLiteral("0.9.0"), QStringLiteral("upgrade")) && ok;
            ok = check(true, QStringLiteral("2.0.0"), QStringLiteral("downgrade")) && ok;
            QCoreApplication::exit(ok ? 0 : 2);
        });
        return app.exec();
    }

    if (plan.checkFinishTiming) {
        // 验证进度收尾：成功 600ms、失败 300ms 的停留，再切页。
        bool ok = true;
        QTimer::singleShot(100, &app, [&qml, &ok]() {
            QObject *root = qml.rootObjects().value(0);
            QObject *ctl = root ? root->property("ctl").value<QObject *>() : nullptr;
            if (!ctl) { qCritical() << "SELFTEST 未找到 controller"; QCoreApplication::exit(2); return; }
            ctl->setProperty("view", "progress");
            QMetaObject::invokeMethod(ctl, "onEngineFinished", Qt::DirectConnection,
                                      Q_ARG(QVariant, 0), Q_ARG(QVariant, QString()));
            const bool early = ctl->property("view").toString() == "progress"
                               && ctl->property("finishing").toBool();
            QTimer::singleShot(300, ctl, [ctl, early, &ok]() {
                if (!early) ok = false;
                QTimer::singleShot(800, ctl, [ctl, early, &ok]() {
                    const bool done = ctl->property("view").toString() == "complete"
                                      && !ctl->property("finishing").toBool();
                    qInfo().noquote() << "SELFTEST 成功收尾: 停留=" << early << "完成页=" << done;
                    if (!done) ok = false;
                    // 失败分支
                    ctl->setProperty("view", "progress");
                    QMetaObject::invokeMethod(ctl, "onEngineFinished", Qt::DirectConnection,
                                              Q_ARG(QVariant, 2), Q_ARG(QVariant, QStringLiteral("boom")));
                    QTimer::singleShot(150, ctl, [ctl, &ok]() {
                        const bool stillProgress = ctl->property("view").toString() == "progress";
                        QTimer::singleShot(250, ctl, [ctl, stillProgress, &ok]() {
                            const bool failure = ctl->property("view").toString() == "failure";
                            qInfo().noquote() << "SELFTEST 失败收尾: 停留=" << stillProgress << "失败页=" << failure;
                            if (!stillProgress || !failure) ok = false;
                            QCoreApplication::exit(ok ? 0 : 2);
                        });
                    });
                });
            });
        });
        return app.exec();
    }

    if (plan.checkWindow) {
        // 真实平台下确认主窗口真的显示出来（截图用的 shotWindow 不算）。
        QTimer::singleShot(1200, &app, []() {
            bool visible = false;
            for (QWindow *w : QGuiApplication::topLevelWindows()) {
                if (w->isVisible() && w->width() > 0 && w->height() > 0) {
                    visible = true;
                    qInfo().noquote() << QStringLiteral("SELFTEST 主窗口可见: %1 %2x%3")
                                             .arg(w->title()).arg(w->width()).arg(w->height());
                }
            }
            if (!visible)
                qCritical().noquote() << "SELFTEST 主窗口未显示";
            QCoreApplication::exit(visible ? 0 : 2);
        });
        return app.exec();
    }

    if (driveOptions) {
        QTimer::singleShot(0, &app, [&qml, &host, &plan]() {
            runSelftestDrive(qml, host, plan, plan.checkOptions);
        });
        return app.exec();
    }

    if (plan.mode == StartMode::SelfTest && !plan.qmlSmoke) {
        qInfo().noquote() << "自检: 根对象" << (qml.rootObjects().isEmpty()
                                                   ? QStringLiteral("?")
                                                   : QString::fromLatin1(qml.rootObjects().first()->metaObject()->className()));
        return 0;
    }

    return app.exec();
}
