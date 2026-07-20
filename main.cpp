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
// work area (screen geometry minus panels/taskbars) for the screen the cursor is on,
// reported by the injected KWin script - QScreen::availableGeometry() does not reflect
// panel-reserved space on this KWin/Wayland setup, so it can't be used for this
QRect gWorkArea;

// state tracked by the persistent drag-watching KWin script (see loadPersistentScript
// below) - which window, if any, is currently being interactively moved by the user,
// and its last known position. Meta+Alt+D pressed while this is set activates DivvyGrid
// for the dragged window instead of workspace.activeWindow (see toggleOverlay).
QString gDragWindowId;
QPoint gDragPos;
bool gDragActive = false;

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

// like loadRunUnload, but never unloads - used for the drag-watching script, which needs
// to stay alive and keep receiving interactiveMoveResize signals for the daemon's entire
// lifetime, not just a single query/commit round-trip.
void loadPersistentScript(const QString &scriptPath, const QString &pluginName) {
    const QString idStr = runProcess("qdbus", {"org.kde.KWin", "/Scripting",
        "org.kde.kwin.Scripting.loadScript", scriptPath, pluginName});
    runProcess("qdbus", {"org.kde.KWin", QString("/Scripting/Script%1").arg(idStr), "run"});
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

    void reportWorkArea(int areaX, int areaY, int areaW, int areaH) {
        gWorkArea = QRect(areaX, areaY, areaW, areaH);
        Q_EMIT workAreaReceived();
    }

    // called continuously by the persistent drag-watching script for whichever window is
    // currently being interactively moved. phase is "started"/"stepped"/"finished", mirroring
    // KWin's interactiveMoveResizeStarted/Stepped/Finished signals.
    void dragTick(const QString &id, const QString &phase, int x, int y) {
        qWarning() << "[DIVVYDEBUG] dragTick" << id << phase << x << y << "gDragWindowId=" << gDragWindowId;
        if (phase == QLatin1String("started")) {
            gDragWindowId = id;
            gDragPos = QPoint(x, y);
            gDragActive = true;
        } else if (phase == QLatin1String("stepped")) {
            if (id != gDragWindowId) return;
            gDragPos = QPoint(x, y);
            Q_EMIT dragStepped();
        } else if (phase == QLatin1String("finished")) {
            if (id != gDragWindowId) return;
            gDragPos = QPoint(x, y);
            Q_EMIT dragFinished();
            gDragActive = false;
            gDragWindowId.clear();
        }
    }

Q_SIGNALS:
    void received();
    void workAreaReceived();
    void dragStepped();
    void dragFinished();
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

// fetches the work area (screen geometry minus panels/taskbars/docks) for the output
// containing (x, y) - QScreen::availableGeometry() does not reflect panel-reserved space
// under this KWin/Wayland setup, so this privileged KWin-script query is used instead.
// KWin.PlacementArea is the clientArea option that actually excludes panels here (verified
// live: PlacementArea/MaximizeArea shrink by the panel's strut, FullScreenArea/ScreenArea/
// MovementArea/MaximizeFullArea do not, and WorkArea/FullArea span all screens combined).
void queryWorkArea(AppService &service, int x, int y) {
    const QString pluginName = "divvygrid-workarea";
    const QString script = QStringLiteral(
        "var screens = workspace.screens;\n"
        "var target = workspace.activeScreen;\n"
        "for (var i = 0; i < screens.length; i++) {\n"
        "    var g = screens[i].geometry;\n"
        "    if (%1 >= g.x && %1 < g.x + g.width && %2 >= g.y && %2 < g.y + g.height) {\n"
        "        target = screens[i];\n"
        "        break;\n"
        "    }\n"
        "}\n"
        "var area = workspace.clientArea(KWin.PlacementArea, target, workspace.currentDesktop);\n"
        "callDBus('org.divvygrid.App', '/App', 'org.divvygrid.App', 'reportWorkArea', Math.round(area.x), Math.round(area.y), Math.round(area.width), Math.round(area.height));\n"
    ).arg(x).arg(y);
    const QString path = writeTempScript("divvygrid-workarea.js", script);

    QEventLoop loop;
    QObject::connect(&service, &AppService::workAreaReceived, &loop, &QEventLoop::quit);
    QTimer::singleShot(1000, &loop, &QEventLoop::quit);

    loadRunUnload(path, pluginName);
    loop.exec();
}

// installs a persistent (never-unloaded) KWin script that hooks every window's
// interactiveMoveResizeStarted/Stepped/Finished signals and reports each one back via
// AppService::dragTick. Must be loaded once at daemon startup - see main().
void startDragWatcher() {
    const QString pluginName = "divvygrid-dragwatch";
    const QString script =
        "function reportDrag(id, phase, x, y) {\n"
        "    callDBus('org.divvygrid.App', '/App', 'org.divvygrid.App', 'dragTick', id, phase, x, y);\n"
        "}\n"
        "function hookWindow(w) {\n"
        "    reportDrag(w.internalId.toString(), 'hooked', 0, 0);\n"
        "    w.interactiveMoveResizeStarted.connect(function () {\n"
        "        reportDrag(w.internalId.toString(), 'started', Math.round(workspace.cursorPos.x), Math.round(workspace.cursorPos.y));\n"
        "    });\n"
        "    w.interactiveMoveResizeStepped.connect(function (geo) {\n"
        "        reportDrag(w.internalId.toString(), 'stepped', Math.round(geo.x), Math.round(geo.y));\n"
        "    });\n"
        "    w.interactiveMoveResizeFinished.connect(function () {\n"
        "        reportDrag(w.internalId.toString(), 'finished', Math.round(w.frameGeometry.x), Math.round(w.frameGeometry.y));\n"
        "    });\n"
        "}\n"
        "var wins = workspace.windowList();\n"
        "for (var i = 0; i < wins.length; i++) hookWindow(wins[i]);\n"
        // workspace.windowAdded's own callback parameter is a different/stale wrapper than
        // what workspace.windowList() returns for the same window afterward - connecting
        // signals directly on it silently never fires them. Re-fetch the canonical window
        // by internalId and hook that instead (confirmed necessary via live testing).
        "workspace.windowAdded.connect(function (w0) {\n"
        "    var id = w0.internalId.toString();\n"
        "    var all = workspace.windowList();\n"
        "    for (var i = 0; i < all.length; i++) {\n"
        "        if (all[i].internalId.toString() === id) { hookWindow(all[i]); break; }\n"
        "    }\n"
        "});\n";
    const QString path = writeTempScript("divvygrid-dragwatch.js", script);
    loadPersistentScript(path, pluginName);
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
    Q_PROPERTY(int externalCursorX READ externalCursorX NOTIFY externalCursorChanged)
    Q_PROPERTY(int externalCursorY READ externalCursorY NOTIFY externalCursorChanged)
    Q_PROPERTY(bool spawnAtCursor READ spawnAtCursor NOTIFY spawnAtCursorChanged)
public:
    using QObject::QObject;

    int externalCursorX() const { return m_externalCursorX; }
    int externalCursorY() const { return m_externalCursorY; }
    bool spawnAtCursor() const { return m_spawnAtCursor; }

    // absolute global screen pixels, updated continuously during a drag-triggered activation
    void setExternalCursor(int x, int y) {
        m_externalCursorX = x;
        m_externalCursorY = y;
        Q_EMIT externalCursorChanged();
    }

    void setSpawnAtCursor(bool v) {
        if (m_spawnAtCursor == v) return;
        m_spawnAtCursor = v;
        Q_EMIT spawnAtCursorChanged();
    }

    void triggerExternalDragStarted() { Q_EMIT externalDragStarted(); }
    void triggerExternalDragFinished() { Q_EMIT externalDragFinished(); }

    Q_INVOKABLE void commit(int x, int y, int w, int h) {
        qWarning() << "[DIVVYDEBUG] Controller::commit" << x << y << w << h;
        applyResize(x, y, w, h);
        Q_EMIT dismissed();
    }

    Q_INVOKABLE void cancel() {
        qWarning() << "[DIVVYDEBUG] Controller::cancel";
        Q_EMIT dismissed();
    }

Q_SIGNALS:
    void dismissed();
    void externalCursorChanged();
    void spawnAtCursorChanged();
    // fires once, right when C++ decides to show the overlay for a drag-triggered
    // activation - equivalent to a MouseArea onPressed, but driven externally
    void externalDragStarted();
    // fires once, when the tracked window's native drag ends (mouse-up) - equivalent to a
    // MouseArea onReleased, but driven externally
    void externalDragFinished();

private:
    int m_externalCursorX = 0;
    int m_externalCursorY = 0;
    bool m_spawnAtCursor = false;
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
    engine.rootContext()->setContextProperty("windowGap", cfg.gap);
    engine.rootContext()->setContextProperty("screenX", 0);
    engine.rootContext()->setContextProperty("screenY", 0);
    engine.rootContext()->setContextProperty("targetScreenWidth", 1920);
    engine.rootContext()->setContextProperty("targetScreenHeight", 1080);
    engine.rootContext()->setContextProperty("availX", 0);
    engine.rootContext()->setContextProperty("availY", 0);
    engine.rootContext()->setContextProperty("availWidth", 1920);
    engine.rootContext()->setContextProperty("availHeight", 1080);

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
    // whether the currently-shown overlay was triggered by Meta+Alt+D during an in-progress
    // window drag, rather than a plain press with nothing being dragged
    bool dragTriggeredActive = false;

    auto toggleOverlay = [&]() {
        if (window && window->isVisible()) {
            window->hide();
            dragTriggeredActive = false;
            return;
        }

        // if a window is mid-drag when the shortcut fires (per the persistent drag-watcher
        // script - see startDragWatcher/AppService::dragTick), target that window and its
        // last known drag position instead of the usual active-window capture
        const bool dragTriggered = gDragActive && !gDragWindowId.isEmpty();
        qWarning() << "[DIVVYDEBUG] toggleOverlay: gDragActive=" << gDragActive << "gDragWindowId=" << gDragWindowId << "dragTriggered=" << dragTriggered;
        if (dragTriggered) {
            gActiveInternalId = gDragWindowId;
            gCursorPos = gDragPos;
        } else {
            // must happen before our own window steals focus from the target window;
            // also populates gCursorPos with the real cursor position (see reportState)
            captureActiveWindow(appService);
        }

        QScreen *screen = QGuiApplication::screenAt(gCursorPos);
        if (!screen) screen = QGuiApplication::primaryScreen();
        const QRect geo = screen->geometry();
        // work area (screen geometry minus panels/taskbars) - the grid canvas and final
        // window placement both need to stay within it so windows don't end up underneath
        // a panel (see queryWorkArea - QScreen::availableGeometry() doesn't reflect this here)
        gWorkArea = QRect();
        queryWorkArea(appService, gCursorPos.x(), gCursorPos.y());
        const QRect avail = gWorkArea.isValid() ? gWorkArea : geo;

        engine.rootContext()->setContextProperty("screenX", geo.x());
        engine.rootContext()->setContextProperty("screenY", geo.y());
        engine.rootContext()->setContextProperty("targetScreenWidth", geo.width());
        engine.rootContext()->setContextProperty("targetScreenHeight", geo.height());
        engine.rootContext()->setContextProperty("availX", avail.x());
        engine.rootContext()->setContextProperty("availY", avail.y());
        engine.rootContext()->setContextProperty("availWidth", avail.width());
        engine.rootContext()->setContextProperty("availHeight", avail.height());

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

        controller.setSpawnAtCursor(dragTriggered);
        if (dragTriggered) {
            controller.setExternalCursor(gCursorPos.x(), gCursorPos.y());
        }

        window->show();
        window->requestActivate();

        if (dragTriggered) {
            dragTriggeredActive = true;
            controller.triggerExternalDragStarted();
        }
    };

    // forwards live cursor position during a drag-triggered activation into the QML
    // preview; ignored if the currently-shown overlay wasn't drag-triggered
    QObject::connect(&appService, &AppService::dragStepped, [&]() {
        qWarning() << "[DIVVYDEBUG] dragStepped signal, dragTriggeredActive=" << dragTriggeredActive << "gDragPos=" << gDragPos;
        if (!dragTriggeredActive) return;
        controller.setExternalCursor(gDragPos.x(), gDragPos.y());
    });

    // the tracked window's native drag ends (mouse-up) - commit the grid selection against
    // it, discarding wherever the native move itself left the window. Only meaningful if the
    // overlay is still actually showing (e.g. not if the user already hit Escape to cancel).
    QObject::connect(&appService, &AppService::dragFinished, [&]() {
        qWarning() << "[DIVVYDEBUG] dragFinished signal, dragTriggeredActive=" << dragTriggeredActive
                   << "window=" << (window != nullptr) << "visible=" << (window && window->isVisible());
        if (!dragTriggeredActive || !window || !window->isVisible()) return;
        controller.setExternalCursor(gDragPos.x(), gDragPos.y());
        controller.triggerExternalDragFinished();
        dragTriggeredActive = false;
    });

    QObject::connect(&controller, &Controller::dismissed, [&]() {
        dragTriggeredActive = false;
    });

    startDragWatcher();

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
