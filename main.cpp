#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQuickWindow>
#include <QScreen>
#include <QCursor>
#include <QPoint>
#include <QProcess>
#include <QFile>
#include <QDir>
#include <QUrl>
#include <QObject>
#include <QDebug>
#include <QDBusConnection>
#include <QEventLoop>
#include <QTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QAction>
#include <QKeySequence>
#include <QHash>
#include <KGlobalAccel>

namespace {

QString gActiveInternalId;
QPoint gCursorPos;
int gGap = 8;

struct MonitorOverride {
    int gridCols = 0; // 0 = not set, fall back to global default
    int gridRows = 0;
};

struct Config {
    int gridCols = 6;
    int gridRows = 4;
    QString mode = QStringLiteral("fullscreen"); // "fullscreen" or "compact"
    int compactWidth = 480;
    int compactHeight = 300;
    int gap = 8; // px, inset from each edge of the final placed window
    QString shortcut = QStringLiteral("Meta+Alt+D"); // Qt portable-text key sequence
    QHash<QString, MonitorOverride> monitors; // keyed by QScreen::name()
};

QString configPath() {
    return QDir::homePath() + "/.config/divvygrid/config.json";
}

void writeDefaultConfig(const Config &c) {
    QDir().mkpath(QDir::homePath() + "/.config/divvygrid");
    QJsonObject obj;
    obj["gridCols"] = c.gridCols;
    obj["gridRows"] = c.gridRows;
    obj["mode"] = c.mode;
    obj["compactWidth"] = c.compactWidth;
    obj["compactHeight"] = c.compactHeight;
    obj["gap"] = c.gap;
    obj["shortcut"] = c.shortcut;
    QJsonObject monitors;
    for (auto it = c.monitors.constBegin(); it != c.monitors.constEnd(); ++it) {
        QJsonObject m;
        m["gridCols"] = it.value().gridCols;
        m["gridRows"] = it.value().gridRows;
        monitors[it.key()] = m;
    }
    obj["monitors"] = monitors;
    QFile f(configPath());
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        f.write(QJsonDocument(obj).toJson(QJsonDocument::Indented));
        f.close();
    }
}

Config loadConfig() {
    Config c;
    QFile f(configPath());
    if (!f.exists()) {
        writeDefaultConfig(c);
        return c;
    }
    if (!f.open(QIODevice::ReadOnly)) return c;
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    f.close();
    if (!doc.isObject()) return c;
    const QJsonObject obj = doc.object();
    if (obj.contains("gridCols")) c.gridCols = obj["gridCols"].toInt(c.gridCols);
    if (obj.contains("gridRows")) c.gridRows = obj["gridRows"].toInt(c.gridRows);
    if (obj.contains("mode")) c.mode = obj["mode"].toString(c.mode);
    if (obj.contains("compactWidth")) c.compactWidth = obj["compactWidth"].toInt(c.compactWidth);
    if (obj.contains("compactHeight")) c.compactHeight = obj["compactHeight"].toInt(c.compactHeight);
    if (obj.contains("gap")) c.gap = obj["gap"].toInt(c.gap);
    if (obj.contains("shortcut")) c.shortcut = obj["shortcut"].toString(c.shortcut);
    if (obj.contains("monitors") && obj["monitors"].isObject()) {
        const QJsonObject monitors = obj["monitors"].toObject();
        for (auto it = monitors.constBegin(); it != monitors.constEnd(); ++it) {
            if (!it.value().isObject()) continue;
            const QJsonObject m = it.value().toObject();
            MonitorOverride mo;
            mo.gridCols = m.value("gridCols").toInt(0);
            mo.gridRows = m.value("gridRows").toInt(0);
            if (mo.gridCols > 0 && mo.gridRows > 0) c.monitors[it.key()] = mo;
        }
    }
    if (c.gridCols < 1) c.gridCols = 1;
    if (c.gridRows < 1) c.gridRows = 1;
    if (c.mode != "fullscreen" && c.mode != "compact") c.mode = "fullscreen";
    if (c.compactWidth < 100) c.compactWidth = 100;
    if (c.compactHeight < 60) c.compactHeight = 60;
    if (c.gap < 0) c.gap = 0;
    if (QKeySequence(c.shortcut).isEmpty()) c.shortcut = QStringLiteral("Meta+Alt+D");
    return c;
}

QString runProcess(const QString &program, const QStringList &args) {
    QProcess p;
    p.start(program, args);
    p.waitForFinished(3000);
    return QString::fromUtf8(p.readAllStandardOutput()).trimmed();
}

QString writeTempScript(const QString &name, const QString &contents) {
    const QString path = QDir::temp().filePath(name);
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning() << "Failed to write temp script" << path;
    }
    f.write(contents.toUtf8());
    f.close();
    return path;
}

void loadRunUnload(const QString &scriptPath, const QString &pluginName) {
    const QString idStr = runProcess("qdbus", {"org.kde.KWin", "/Scripting",
        "org.kde.kwin.Scripting.loadScript", scriptPath, pluginName});
    runProcess("qdbus", {"org.kde.KWin", QString("/Scripting/Script%1").arg(idStr), "run"});
    runProcess("qdbus", {"org.kde.KWin", "/Scripting",
        "org.kde.kwin.Scripting.unloadScript", pluginName});
}

} // namespace

// Receives a callback from an injected KWin script via callDBus(), since plain
// (non-declarative) KWin scripts have no working config/file API to report data back.
class AppService : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.divvygrid.App")
public:
    using QObject::QObject;

public Q_SLOTS:
    // Wayland clients can't query the global pointer position (QCursor::pos() is
    // unreliable/stale here, especially right as a global shortcut fires and our app
    // has no focused surface yet), so the cursor position is captured via the same
    // injected KWin script that grabs the active window - workspace.cursorPos is a
    // privileged compositor-side API, not a regular client query.
    void reportState(const QString &id, int cursorX, int cursorY) {
        gActiveInternalId = id;
        gCursorPos = QPoint(cursorX, cursorY);
        Q_EMIT received();
    }

Q_SIGNALS:
    void received();
};

namespace {

void captureActiveWindow(AppService &service) {
    const QString pluginName = "divvygrid-query";
    const QString script =
        "var w = workspace.activeWindow;\n"
        "var id = w ? w.internalId.toString() : '';\n"
        "callDBus('org.divvygrid.App', '/App', 'org.divvygrid.App', 'reportState', id, workspace.cursorPos.x, workspace.cursorPos.y);\n";
    const QString path = writeTempScript("divvygrid-query.js", script);

    QEventLoop loop;
    QObject::connect(&service, &AppService::received, &loop, &QEventLoop::quit);
    QTimer::singleShot(1000, &loop, &QEventLoop::quit);

    loadRunUnload(path, pluginName);
    loop.exec();
}

void applyResize(int x, int y, int w, int h) {
    if (gActiveInternalId.isEmpty()) {
        qWarning() << "No captured active window id, skipping resize";
        return;
    }
    // inset by the configured gap so adjacent tiled windows have visible
    // breathing room between them, instead of touching edge-to-edge
    const int inset = gGap / 2;
    const int gx = x + inset;
    const int gy = y + inset;
    const int gw = qMax(50, w - gGap);
    const int gh = qMax(50, h - gGap);
    const QString pluginName = "divvygrid-resize";
    const QString script = QStringLiteral(
        "var windows = workspace.windowList();\n"
        "for (var i = 0; i < windows.length; i++) {\n"
        "    if (windows[i].internalId.toString() === '%1') {\n"
        "        windows[i].setMaximize(false, false);\n"
        "        windows[i].frameGeometry = { x: %2, y: %3, width: %4, height: %5 };\n"
        "        break;\n"
        "    }\n"
        "}\n"
    ).arg(gActiveInternalId).arg(gx).arg(gy).arg(gw).arg(gh);
    const QString path = writeTempScript("divvygrid-resize.js", script);
    loadRunUnload(path, pluginName);
}

} // namespace

class Controller : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;

    Q_INVOKABLE void commit(int x, int y, int w, int h) {
        applyResize(x, y, w, h);
        Q_EMIT dismissed();
    }

    Q_INVOKABLE void cancel() {
        Q_EMIT dismissed();
    }

Q_SIGNALS:
    void dismissed();
};

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    app.setQuitOnLastWindowClosed(false);
    QGuiApplication::setDesktopFileName(QStringLiteral("divvygrid"));

    AppService appService;
    QDBusConnection::sessionBus().registerService("org.divvygrid.App");
    QDBusConnection::sessionBus().registerObject("/App", &appService, QDBusConnection::ExportAllSlots);

    const Config cfg = loadConfig();
    gGap = cfg.gap;

    Controller controller;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("controller", &controller);
    engine.rootContext()->setContextProperty("gridCols", cfg.gridCols);
    engine.rootContext()->setContextProperty("gridRows", cfg.gridRows);
    engine.rootContext()->setContextProperty("overlayMode", cfg.mode);
    engine.rootContext()->setContextProperty("compactWidth", cfg.compactWidth);
    engine.rootContext()->setContextProperty("compactHeight", cfg.compactHeight);
    engine.rootContext()->setContextProperty("screenX", 0);
    engine.rootContext()->setContextProperty("screenY", 0);
    engine.rootContext()->setContextProperty("targetScreenWidth", 1920);
    engine.rootContext()->setContextProperty("targetScreenHeight", 1080);

    const QString qmlPath = QDir::homePath() + "/.local/share/divvygrid/main.qml";
    QQmlComponent component(&engine, QUrl::fromLocalFile(qmlPath));
    if (component.status() != QQmlComponent::Ready) {
        qWarning() << "Failed to load QML from" << qmlPath << component.errorString();
        return -1;
    }

    // wlr-layer-shell binds a surface to a single Wayland output when the surface is
    // created, and that binding can't be changed afterward - QWindow::setScreen() on an
    // already-shown layer-shell window is a no-op for repositioning it to a different
    // monitor. So instead of reusing one window forever, we recreate it whenever the
    // target screen changes.
    QQuickWindow *window = nullptr;
    QScreen *windowScreen = nullptr;

    auto toggleOverlay = [&]() {
        if (window && window->isVisible()) {
            window->hide();
            return;
        }

        // must happen before our own window steals focus from the target window;
        // also populates gCursorPos with the real cursor position (see reportState)
        captureActiveWindow(appService);

        QScreen *screen = QGuiApplication::screenAt(gCursorPos);
        if (!screen) screen = QGuiApplication::primaryScreen();
        const QRect geo = screen->geometry();

        engine.rootContext()->setContextProperty("screenX", geo.x());
        engine.rootContext()->setContextProperty("screenY", geo.y());
        engine.rootContext()->setContextProperty("targetScreenWidth", geo.width());
        engine.rootContext()->setContextProperty("targetScreenHeight", geo.height());

        // per-monitor grid override (keyed by QScreen::name(), e.g. "DP-2") takes
        // priority; otherwise fall back to the global default, swapping cols/rows to
        // keep grid cells roughly square-ish on a portrait screen
        const auto overrideIt = cfg.monitors.constFind(screen->name());
        if (overrideIt != cfg.monitors.constEnd()) {
            engine.rootContext()->setContextProperty("gridCols", overrideIt.value().gridCols);
            engine.rootContext()->setContextProperty("gridRows", overrideIt.value().gridRows);
        } else {
            const bool portrait = geo.height() > geo.width();
            engine.rootContext()->setContextProperty("gridCols", portrait ? cfg.gridRows : cfg.gridCols);
            engine.rootContext()->setContextProperty("gridRows", portrait ? cfg.gridCols : cfg.gridRows);
        }

        if (window && windowScreen != screen) {
            window->hide();
            window->deleteLater();
            window = nullptr;
        }

        if (!window) {
            auto *obj = component.create(engine.rootContext());
            window = qobject_cast<QQuickWindow *>(obj);
            if (!window) {
                qWarning() << "Root object is not a QQuickWindow";
                delete obj;
                return;
            }
            window->setScreen(screen);
            windowScreen = screen;
            QObject::connect(&controller, &Controller::dismissed, window, &QQuickWindow::hide);
        }

        window->show();
        window->requestActivate();
    };

    const QKeySequence shortcut(cfg.shortcut);
    auto *action = new QAction(&app);
    action->setObjectName(QStringLiteral("show_overlay"));
    action->setText(QStringLiteral("DivvyGrid: Show overlay"));
    KGlobalAccel::self()->setDefaultShortcut(action, {shortcut});
    KGlobalAccel::self()->setShortcut(action, {shortcut});
    QObject::connect(action, &QAction::triggered, toggleOverlay);

    return app.exec();
}

#include "main.moc"
