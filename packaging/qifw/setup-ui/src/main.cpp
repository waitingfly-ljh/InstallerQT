// Installer shell entry point.
// Only three responsibilities: parse our own command line, decide "development mode /
// packaged mode", and hand the host objects to QML.
// UI logic lives in the root QML files and pages/; install/uninstall process management
// lives in setupengine.cpp.
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
#include <QLocale>
#include <QQuickWindow>
#include <QStandardPaths>
#include <QTranslator>
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

// Shell start mode: decided by the command line; QML selects the first screen from it.
enum class StartMode { Normal, SelfTest, Help };

struct LaunchPlan {
    StartMode mode = StartMode::Normal;
    bool silentInstall = false;
    bool silentUninstall = false;
    QString targetDir;
    QString payloadPath;
    QString logPath;
    // --uninstall / --install-dir: used by the system uninstall entry and the self-contained uninstaller.
    bool uninstall = false;
    QString installDirOverride;
    // --uninstaller <path>: uninstaller source file extracted by the Setup.exe launcher (deployed after a successful install).
    QString uninstallerPath;
    // Whether --silent was given (arguments after it are passed through to the engine).
    bool silent = false;
    // --selftest --qml-smoke [--view <name>] [--option <key>] [--dir <path>]
    bool qmlSmoke = false;
    QString smokeView;
    int smokeOption = 0;
    QString smokeDir;
    // --selftest --check-options [--dir <path>]: only asserts directory/space, does not start the install.
    bool checkOptions = false;
    // Self-test extension: --check-launch <dir> verifies launching the main program.
    bool checkWindow = false;
    QString checkLaunchDir;
    QString checkShortcutDir;
    bool checkFinishTiming = false;
    bool checkRunMode = false;
    // Test hook: silent install uses the install options page defaults (shortcut/.3mf/launch after install),
    // so the packaging loop can verify "install options are restored on uninstall".
    bool withOptions = false;
    // --lang <code>: explicit UI language; empty means "follow the system locale, then English".
    QString lang;
};

LaunchPlan parseArgs(QGuiApplication &app)
{
    LaunchPlan plan;
    const QStringList args = app.arguments();

    // Arguments after --silent (in -t <dir> / pr ...) are passed through to the engine verbatim; `--` is also supported as a separator.
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
        if (afterSeparator) {
            // --lang is a shell option, not an engine option: consume it wherever it appears so
            // "--silent in -t <dir> --lang zh_CN" does not leak it into the QIFW command line.
            if (a == QStringLiteral("--lang") && i + 1 < args.size()) {
                plan.lang = args.at(++i);
                continue;
            }
            if (a.startsWith(QStringLiteral("--lang="))) {
                plan.lang = a.mid(7);
                continue;
            }
            passthrough << a;
        }
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
        } else if (a == QStringLiteral("--lang") && i + 1 < own.size()) {
            plan.lang = own.at(++i);
        } else if (a.startsWith(QStringLiteral("--lang="))) {
            plan.lang = a.mid(7);
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

// UI language: explicit --lang wins, then the system locale (zh* -> zh_CN), then English.
struct LanguageChoice {
    QString code;    // "en" or "zh_CN" (or an unsupported code, which falls back later)
    QString source;  // human-readable origin, logged so support can see why a language was picked
};

LanguageChoice resolveLanguage(const LaunchPlan &plan)
{
    LanguageChoice c;
    if (!plan.lang.isEmpty()) {
        QString code = plan.lang.trimmed();
        if (code.startsWith(QLatin1String("zh"), Qt::CaseInsensitive))
            code = QStringLiteral("zh_CN");
        else if (code.startsWith(QLatin1String("en"), Qt::CaseInsensitive))
            code = QStringLiteral("en");
        c.code = code;
        c.source = QStringLiteral("command line");
        return c;
    }
    const QString sys = QLocale::system().name();
    if (sys.startsWith(QLatin1String("zh"), Qt::CaseInsensitive)) {
        c.code = QStringLiteral("zh_CN");
        c.source = QStringLiteral("system locale");
    } else {
        c.code = QStringLiteral("en");
        c.source = QStringLiteral("default");
    }
    return c;
}

// Installs the translator for `lang` and returns the language actually in effect. A missing or
// unloadable .qm falls back to English with a warning: a broken translation must never block startup.
QString installUiTranslator(QGuiApplication &app, const QString &lang)
{
    if (lang == QLatin1String("en"))
        return lang;
    auto *translator = new QTranslator(&app);
    const QString path = QStringLiteral(":/i18n/OrbbecSlicerSetup_%1.qm").arg(lang);
    if (translator->load(path) && app.installTranslator(translator)) {
        qInfo().noquote() << QStringLiteral("UI language: %1 (translation loaded from %2)").arg(lang, path);
        return lang;
    }
    delete translator;
    qWarning().noquote() << QStringLiteral("UI language: %1 has no translation (%2); falling back to English")
                                .arg(lang, path);
    return QStringLiteral("en");
}

// Screenshot mode (only with -DORBBEC_SETUP_SHOT): place the controller at a given view.
// View names match SetupController.view; uninstall-* also switches the sidebar to uninstall steps.
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
    } else if (name == QLatin1String("rollback")) {
        // The rollback dialog is an overlay on the maintenance screen, not its own page.
        m.insert(QStringLiteral("view"), QStringLiteral("maintenance"));
        m.insert(QStringLiteral("rollback"), true);
    } else if (name == QLatin1String("failure-code")) {
        // Skeleton B of the failure dialog (error code + retry, no step list).
        m.insert(QStringLiteral("view"), QStringLiteral("failure"));
        m.insert(QStringLiteral("noSteps"), true);
        m.insert(QStringLiteral("failure"), 5);
        m.insert(QStringLiteral("message"),
                 QStringLiteral("The configuration folder could not be written. Check the permissions and try again."));
    } else if (!name.isEmpty()) {
        m.insert(QStringLiteral("view"), name);
    }
    return m;
}

#ifdef ORBBEC_SETUP_SHOT
// Screenshot singleton: QML writes a path to the capture key; after the window shows, grab one PNG and quit.
QObject *makeShotCapture(QQmlEngine *engine, QJSEngine *js)
{
    Q_UNUSED(js)
    auto *map = new QQmlPropertyMap(engine);
    QObject::connect(map, &QQmlPropertyMap::valueChanged, engine,
                     [map](const QString &key, const QVariant &value) {
                         if (key != QLatin1String("capture"))
                             return;
                         const QString path = value.toString();
                         qInfo().noquote() << "Screenshot request:" << path;
                         QTimer::singleShot(1500, map, [path]() {
                             bool saved = false;
                             for (QWindow *win : QGuiApplication::topLevelWindows()) {
                                 if (!win->isVisible())
                                     continue;
                                 // Always render the scene here instead of screenshotting the window handle:
                                 //  - before the first composite (isExposed() false) the handle grab yields
                                 //    background/a black block;
                                 //  - the shell window is translucent (rounded corners via an AppFrame mask),
                                 //    and QScreen::grabWindow on a layered window only returns white.
                                 // QQuickWindow::grabWindow() re-renders the scene graph, so the mask alpha is
                                 // included and the PNG keeps transparent corner pixels.
                                 auto *quick = qobject_cast<QQuickWindow *>(win);
                                 if (quick)
                                     saved = quick->grabWindow().save(path, "PNG");
                                 else
                                     saved = win->screen()->grabWindow(win->winId()).save(path, "PNG");
                                 qInfo().noquote() << "Screenshot saved:" << path << saved;
                                 break;
                             }
                             QCoreApplication::quit();
                         });
                     });
    return map;
}
#endif

// Self-test: place the options page at the given directory, read button availability and reason, and if needed actually click "Install" once.
void runSelftestDrive(QQmlApplicationEngine &qml, SetupHost &host, const LaunchPlan &plan, bool checkOnly)
{
    QObject *root = qml.rootObjects().value(0);
    if (!root) {
        qCritical().noquote() << "SELFTEST root object is null";
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
        // --dir passes the "parent folder" (matching UI semantics); the host composes the final directory with the same rule.
        options->setProperty("installParentDir", plan.smokeDir);
        options->setProperty("installDir", host.installDirForParent(plan.smokeDir));
    }

    QObject *page = root->findChild<QObject *>(QStringLiteral("optionsPage"));
    if (!page) {
        qCritical().noquote() << "SELFTEST optionsPage not found";
        QCoreApplication::exit(2);
        return;
    }

    const bool canInstall = page->property("canInstall").toBool();
    const QString problem = page->property("dirProblem").toString();
    const QString dir = page->property("installParentDir").toString();
    // Parent folder -> final install directory: --check-options asserts the composition rule with it (no real install needed).
    const QString effectiveDir = page->property("effectiveInstallDir").toString();
    qInfo().noquote() << QStringLiteral("SELFTEST location=[%1] installTo=[%2] canInstall=%3 problem=%4")
                             .arg(QDir::toNativeSeparators(dir), QDir::toNativeSeparators(effectiveDir))
                             .arg(canInstall ? QStringLiteral("true") : QStringLiteral("false"), problem);
    qInfo().noquote() << QStringLiteral("SELFTEST directory check done: %1 view=%2")
                             .arg(QString::fromLatin1(root->metaObject()->className()),
                                  ctl ? ctl->property("view").toString() : QStringLiteral("?"));
    if (ctl) {
        const QVariantMap installed = ctl->property("installed").toMap();
        qInfo().noquote() << QStringLiteral("SELFTEST installed: installed=%1 version=%2 dir=%3 targetVersion=%4 mode=%5")
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

    const auto flag = [options](const char *key) {
        return options && options->property(key).toBool();
    };
    qInfo().noquote() << QStringLiteral("Self-test: handing to engine dir=[%1] shortcut=%2 .3mf=%3 .stl=%4 launchAfterInstall=%5")
                             .arg(QDir::toNativeSeparators(dir))
                             .arg(flag("shortcutDesktop") ? 1 : 0)
                             .arg(flag("assoc3mf") ? 1 : 0)
                             .arg(flag("assocStl") ? 1 : 0)
                             .arg(flag("launchAfterInstall") ? 1 : 0);

    QObject::connect(host.engine(), &SetupEngine::finished, &qml,
                     [](int code, const QString &summary) {
                         qInfo().noquote() << QStringLiteral("SELFTEST install button hit: engine received %1 %2")
                                                  .arg(code)
                                                  .arg(summary);
                         // The engine's finished is emitted synchronously inside the QML slot; defer exit to the next
                         // turn so the controller can switch the view to the progress/failure page first.
                         QTimer::singleShot(0, qApp, []() { QCoreApplication::exit(0); });
                     });
    // Fallback: exit even if the engine does not finish immediately (e.g. a payload exists and the install really runs).
    QTimer::singleShot(50, qApp, []() { QCoreApplication::exit(0); });
    QMetaObject::invokeMethod(page, "installRequested", Qt::DirectConnection);
}

} // namespace

// A frameless window (Qt.FramelessWindowHint) makes Qt omit WS_MINIMIZEBOX, so Windows does not
// translate a taskbar button click into a minimize. Add that style bit here to restore the native
// "click taskbar to minimize, click again to restore" behavior; do not add WS_MAXIMIZEBOX — the
// product does not allow maximizing, and adding it would introduce unwanted system gestures.
// showMinimized() from the custom title bar goes through Qt's window state interface and is unaffected by this style bit.
static void restoreTaskbarMinimize(QQuickWindow *window)
{
    if (!window)
        return;
#ifdef Q_OS_WIN
    // winId() creates the native window immediately if it does not exist yet; it usually exists already when visible: true in QML.
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

// Add the style bit to all current top-level QQuickWindows. The window is not the QML root object
// (App.qml's root is an Item; the window is an inner ApplicationWindow), so find it via
// topLevelWindows() rather than rootObjects().
// Handle each only once: after marking, do not repeat; then connect visibilityChanged to cover
// cases where Qt resets the window style on show/state changes.
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
        qInfo().noquote() << QStringLiteral("Taskbar minimize: added WS_MINIMIZEBOX to window");
    }
#endif
}

int main(int argc, char *argv[])
{
    // --selftest runs on the minimal platform: QML must load even without a window.
    // Exception: when a screenshot is needed (ORBBEC_SETUP_SHOT_DIR non-empty), a real window is required, otherwise no pixels can be grabbed.
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
    // Window/taskbar icon: same as the brand icon embedded in the exe.
    QGuiApplication::setWindowIcon(QIcon(QStringLiteral(":/app.ico")));

    const LaunchPlan plan = parseArgs(app);

    // The WIN32 subsystem has no console: diagnostics go to %LOCALAPPDATA%\Orbbec\OrbbecSlicerSetup\logs\setup-shell.log,
    // from which --selftest / screenshot scripts read the failure reason.
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


    // Resolve and install the UI language before the QML engine exists: QML evaluates qsTr() while
    // loading the root component, so a translator installed later would leave the first screen in English.
    const LanguageChoice language = resolveLanguage(plan);
    const QString uiLanguage = installUiTranslator(app, language.code);
    qInfo().noquote() << QStringLiteral("UI language resolved: %1 (source: %2)").arg(uiLanguage, language.source);

    // --selftest --lang zh_CN: prove the translation actually took effect, otherwise a missing or
    // stale .qm would silently leave the Chinese UI in English while every other assertion still passes.
    if (plan.mode == StartMode::SelfTest && uiLanguage == QLatin1String("zh_CN")) {
        const QString probe = QCoreApplication::translate("AppFrame", "OrbbecSlicer Setup Wizard");
        const bool translated = probe != QLatin1String("OrbbecSlicer Setup Wizard");
        qInfo().noquote() << QStringLiteral("SELFTEST language: zh_CN probe=[%1] translated=%2")
                                 .arg(probe, translated ? QStringLiteral("true") : QStringLiteral("false"));
        if (!translated)
            return 2;
    }

    Environment env;
    SetupHost host(&env);
    if (!plan.logPath.isEmpty())
        host.engine()->setLogPath(plan.logPath);

    // Silent mode: do not load the UI; the exit code is the result.
    if (plan.silent || plan.silentInstall || plan.silentUninstall) {
        // Some failure/fast paths emit finished synchronously before entering the event loop; record it and return
        // directly, otherwise exit() before exec() is ignored and the process never quits.
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
        // For verifying the cancel path: with ORBBEC_SETUP_SELFTEST_CANCEL_MS=300, request cancel after 300ms.
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
            // Test hook: silent uninstall has no UI to check "keep user data folder", so enable it via an
            // environment variable, letting the packaging loop verify "keep user data directory" and
            // "delete the whole install directory" do not affect each other.
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


    // --selftest --check-desktop-shortcut <dir>: verify a desktop shortcut to the main program can be created.
    if (plan.mode == StartMode::SelfTest && !plan.checkShortcutDir.isEmpty()) {
        const bool created = host.engine()->ensureDesktopShortcut(plan.checkShortcutDir);
        const QString lnk = QDir(QStandardPaths::writableLocation(QStandardPaths::DesktopLocation))
                                .filePath(QStringLiteral("OrbbecSlicer.lnk"));
        const bool exists = QFileInfo::exists(lnk);
        qInfo().noquote() << QStringLiteral("SELFTEST desktop shortcut: created=%1 exists=%2 path=%3")
                                 .arg(created ? QStringLiteral("true") : QStringLiteral("false"),
                                      exists ? QStringLiteral("true") : QStringLiteral("false"),
                                      QDir::toNativeSeparators(lnk));
        return (created && exists) ? 0 : 2;
    }

    // --selftest --check-launch <dir>: verify "launch now" can start the main program in the install directory.
    if (plan.mode == StartMode::SelfTest && !plan.checkLaunchDir.isEmpty()) {
        const bool ok = host.launchApp(plan.checkLaunchDir);
        qInfo().noquote() << QStringLiteral("SELFTEST launch main program: %1 dir=%2")
                                 .arg(ok ? QStringLiteral("true") : QStringLiteral("false"),
                                      QDir::toNativeSeparators(plan.checkLaunchDir));
        return ok ? 0 : 2;
    }

    QQmlApplicationEngine qml(qApp);
    QObject::connect(&qml, &QQmlApplicationEngine::warnings, &app, [](const QList<QQmlError> &errs) {
        for (const QQmlError &e : errs)
            qCritical().noquote() << "QML warning" << e.url().toString() << e.line() << e.description();
    });

    bool qmlFailed = false;
    QObject::connect(&qml, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [&qmlFailed](const QUrl &url) {
                         qmlFailed = true;
                         qCritical().noquote() << "QML load failed:" << url.toString();
                     });

#ifdef ORBBEC_SETUP_SHOT
    qmlRegisterSingletonType<QQmlPropertyMap>("OrbbecShot", 1, 0, "QmlShot", makeShotCapture);
    const QString shotView = plan.smokeView.isEmpty() ? qEnvironmentVariable("ORBBEC_SETUP_SHOT")
                                                      : plan.smokeView;
    qml.rootContext()->setContextProperty(QStringLiteral("shotModel"), shotModelFor(shotView));
#else
    if (plan.qmlSmoke) {
        qCritical().noquote() << "--qml-smoke is only available in screenshot builds (-DORBBEC_SETUP_SHOT=ON)";
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
    // Effective UI language ("en" / "zh_CN"): UiTheme picks its font family from it.
    qml.rootContext()->setContextProperty(QStringLiteral("appLanguage"), uiLanguage);
    // License text: read from the embedded resource here because XMLHttpRequest refuses qrc:/ reads
    // unless QML_XHR_ALLOW_FILE_READ is set. LicensePage falls back to a short notice if it is empty.
    QFile eula(QStringLiteral(":/eula.txt"));
    QString eulaText;
    if (eula.open(QIODevice::ReadOnly | QIODevice::Text))
        eulaText = QString::fromUtf8(eula.readAll());
    else
        qWarning().noquote() << QStringLiteral("License resource missing: :/eula.txt");
    qml.rootContext()->setContextProperty(QStringLiteral("eulaText"), eulaText);
    qml.rootContext()->setContextProperty(QStringLiteral("Host"), &host);
    qml.rootContext()->setContextProperty(QStringLiteral("SetupEngine"), host.engine());

    const bool driveOptions = plan.mode == StartMode::SelfTest
                              && (plan.checkOptions || host.selfTestOptions());
    const QString entry = (plan.mode == StartMode::SelfTest && !driveOptions && !plan.qmlSmoke
                           && !plan.checkWindow && !plan.checkFinishTiming && !plan.checkRunMode)
                              ? QStringLiteral("LoadEntry")
                              : QStringLiteral("App");
    qml.load(QUrl(QStringLiteral("qrc:/SetupUi/%1.qml").arg(entry)));

    if (qmlFailed)
        return 2;

    // Taskbar minimize: the window is an ApplicationWindow created inside QML, later than load returns,
    // and Qt may reset the style on show/state changes. Scan at a few time points; on a hit, mark it and
    // connect visibilityChanged, after which the window maintains itself.
    for (int delayMs : {0, 50, 200, 500, 1200}) {
        QTimer::singleShot(delayMs, &app, []() { applyTaskbarMinimizeToWindows(); });
    }

    if (plan.checkRunMode) {
        // Verify "the Complete page uses the runMode fixed when Install was clicked", not a mode recomputed after install.
        QTimer::singleShot(100, &app, [&qml]() {
            QObject *root = qml.rootObjects().value(0);
            QObject *ctl = root ? root->property("ctl").value<QObject *>() : nullptr;
            if (!ctl) { qCritical() << "SELFTEST controller not found"; QCoreApplication::exit(2); return; }
            ctl->setProperty("targetVersion", QStringLiteral("1.0.0"));
            const auto check = [ctl](const QString &target, bool installed, const QString &version, const QString &expect) {
                QVariantMap m;
                m.insert(QStringLiteral("installed"), installed);
                m.insert(QStringLiteral("version"), version);
                m.insert(QStringLiteral("installDir"), installed ? QStringLiteral("X") : QString());
                ctl->setProperty("installed", m);
                ctl->setProperty("targetVersion", target);
                QMetaObject::invokeMethod(ctl, "beginInstall", Qt::DirectConnection);
                const QString got = ctl->property("runMode").toString();
                qInfo().noquote() << QStringLiteral("SELFTEST runMode target=%1 installed=%2 version=%3 got=%4 expect=%5")
                                         .arg(target).arg(installed ? 1 : 0).arg(version, got, expect);
                return got == expect;
            };
            bool ok = true;
            ok = check(QStringLiteral("1.0.0"), false, QString(), QStringLiteral("fresh")) && ok;
            ok = check(QStringLiteral("1.0.0"), true, QStringLiteral("1.0.0"), QStringLiteral("repair")) && ok;
            ok = check(QStringLiteral("1.0.0"), true, QStringLiteral("0.9.0"), QStringLiteral("upgrade")) && ok;
            ok = check(QStringLiteral("1.0.0"), true, QStringLiteral("2.0.0"), QStringLiteral("downgrade")) && ok;
            // A prerelease sorts below its release, so 1.0.0-beta.1 over 1.0.0 is a downgrade...
            ok = check(QStringLiteral("1.0.0-beta.1"), true, QStringLiteral("1.0.0"), QStringLiteral("downgrade")) && ok;
            // ...and the trailer's 4-byte truncated "0.4." must still read as 0.4.0, not as a downgrade of
            // 0.4.0-beta.1 (the regression this selftest pins).
            ok = check(QStringLiteral("0.4."), true, QStringLiteral("0.4.0-beta.1"), QStringLiteral("upgrade")) && ok;
            ok = check(QStringLiteral("0.4.0-beta.1"), true, QStringLiteral("0.4.0-beta.1"), QStringLiteral("repair")) && ok;
            QCoreApplication::exit(ok ? 0 : 2);
        });
        return app.exec();
    }

    if (plan.checkFinishTiming) {
        // Verify progress finalization: dwell 600ms on success, 300ms on failure, then switch page.
        bool ok = true;
        QTimer::singleShot(100, &app, [&qml, &ok]() {
            QObject *root = qml.rootObjects().value(0);
            QObject *ctl = root ? root->property("ctl").value<QObject *>() : nullptr;
            if (!ctl) { qCritical() << "SELFTEST controller not found"; QCoreApplication::exit(2); return; }
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
                    qInfo().noquote() << "SELFTEST success finalize: dwell=" << early << "completePage=" << done;
                    if (!done) ok = false;
                    // Failure branch
                    ctl->setProperty("view", "progress");
                    QMetaObject::invokeMethod(ctl, "onEngineFinished", Qt::DirectConnection,
                                              Q_ARG(QVariant, 2), Q_ARG(QVariant, QStringLiteral("boom")));
                    QTimer::singleShot(150, ctl, [ctl, &ok]() {
                        const bool stillProgress = ctl->property("view").toString() == "progress";
                        QTimer::singleShot(250, ctl, [ctl, stillProgress, &ok]() {
                            const bool failure = ctl->property("view").toString() == "failure";
                            qInfo().noquote() << "SELFTEST failure finalize: dwell=" << stillProgress << "failurePage=" << failure;
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
        // On the real platform, confirm the main window actually shows (the shotWindow used for screenshots does not count).
        QTimer::singleShot(1200, &app, []() {
            bool visible = false;
            for (QWindow *w : QGuiApplication::topLevelWindows()) {
                if (w->isVisible() && w->width() > 0 && w->height() > 0) {
                    visible = true;
                    qInfo().noquote() << QStringLiteral("SELFTEST main window visible: %1 %2x%3")
                                             .arg(w->title()).arg(w->width()).arg(w->height());
                }
            }
            if (!visible)
                qCritical().noquote() << "SELFTEST main window not shown";
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
        qInfo().noquote() << "Self-test: root object" << (qml.rootObjects().isEmpty()
                                                   ? QStringLiteral("?")
                                                   : QString::fromLatin1(qml.rootObjects().first()->metaObject()->className()));
        return 0;
    }

    return app.exec();
}
