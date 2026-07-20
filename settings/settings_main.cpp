// divvygrid-settings — small standalone GUI to edit ~/.config/divvygrid/config.json
// without hand-editing JSON, and to restart the divvygrid daemon so changes take
// effect (the daemon only reads config once, at startup).
//
// Kept deliberately simple: QtWidgets, one window, no fancy styling. This app
// intentionally does NOT link against the divvygrid daemon target or share any
// code with main.cpp — it only needs to agree on the on-disk JSON schema.

#include <QApplication>
#include <QWidget>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QFormLayout>
#include <QGroupBox>
#include <QLabel>
#include <QComboBox>
#include <QSpinBox>
#include <QCheckBox>
#include <QPushButton>
#include <QKeySequenceEdit>
#include <QScrollArea>
#include <QMessageBox>
#include <QGuiApplication>
#include <QScreen>
#include <QFile>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QTimer>
#include <QCloseEvent>
#include <QVector>
#include <QTextStream>
#include <QRegularExpression>

namespace {

QString configPath() {
    return QDir::homePath() + "/.config/divvygrid/config.json";
}

QString autostartDesktopPath() {
    return QDir::homePath() + "/.config/autostart/divvygrid.desktop";
}

bool isAutostartEnabled() {
    QFile f(autostartDesktopPath());
    if (!f.exists()) return false;
    if (!f.open(QIODevice::ReadOnly)) return true; // exists but unreadable - assume enabled
    const QString contents = QString::fromUtf8(f.readAll());
    f.close();
    // a Hidden=true line disables a .desktop entry per the XDG spec
    return !contents.contains(QStringLiteral("Hidden=true"));
}

void setAutostartEnabled(bool enabled) {
    const QString path = autostartDesktopPath();
    QFile f(path);
    if (!f.exists()) {
        if (!enabled) return; // nothing to disable
        QDir().mkpath(QDir::homePath() + "/.config/autostart");
        QFile out(path);
        if (out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            QTextStream ts(&out);
            ts << "[Desktop Entry]\n"
                  "Type=Application\n"
                  "Name=DivvyGrid\n"
                  "Comment=Click-drag grid window placement (background service)\n"
                  "Exec=" << QDir::homePath() << "/.local/bin/divvygrid\n"
                  "Icon=preferences-desktop-virtual\n"
                  "NoDisplay=true\n"
                  "X-KDE-StartupNotify=false\n"
                  "X-KDE-autostart-phase=1\n";
        }
        return;
    }
    if (!f.open(QIODevice::ReadOnly)) return;
    QString contents = QString::fromUtf8(f.readAll());
    f.close();
    contents.remove(QRegularExpression("^Hidden=.*\\n?", QRegularExpression::MultilineOption));
    if (!enabled) contents += "Hidden=true\n";
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        f.write(contents.toUtf8());
        f.close();
    }
}

struct MonitorRow {
    QString name;
    QCheckBox *enable = nullptr;
    QSpinBox *cols = nullptr;
    QSpinBox *rows = nullptr;
};

} // namespace

class SettingsWindow : public QWidget {
    Q_OBJECT
public:
    SettingsWindow() {
        setWindowTitle("DivvyGrid Settings");

        auto *outer = new QVBoxLayout(this);

        // --- Mode ---
        auto *modeBox = new QGroupBox("Overlay Mode");
        auto *modeForm = new QFormLayout(modeBox);
        m_mode = new QComboBox();
        m_mode->addItem("Fullscreen", "fullscreen");
        m_mode->addItem("Compact", "compact");
        modeForm->addRow("Mode:", m_mode);

        m_compactWidth = new QSpinBox();
        m_compactWidth->setRange(100, 10000);
        m_compactWidth->setValue(480);
        modeForm->addRow("Compact width:", m_compactWidth);

        m_compactHeight = new QSpinBox();
        m_compactHeight->setRange(60, 10000);
        m_compactHeight->setValue(300);
        modeForm->addRow("Compact height:", m_compactHeight);

        m_compactAtCursor = new QCheckBox("Spawn compact overlay at mouse cursor");
        m_compactAtCursor->setChecked(false);
        modeForm->addRow("", m_compactAtCursor);

        connect(m_mode, &QComboBox::currentIndexChanged, this, &SettingsWindow::updateCompactEnabled);
        outer->addWidget(modeBox);

        // --- General ---
        auto *generalBox = new QGroupBox("General");
        auto *generalForm = new QFormLayout(generalBox);

        m_gap = new QSpinBox();
        m_gap->setRange(0, 500);
        m_gap->setValue(8);
        generalForm->addRow("Gap (px):", m_gap);

        m_shortcut = new QKeySequenceEdit();
        generalForm->addRow("Global shortcut:", m_shortcut);
        auto *shortcutHint = new QLabel("Press the new key combination, or leave as-is.");
        shortcutHint->setStyleSheet("color: gray; font-size: 11px;");
        generalForm->addRow("", shortcutHint);

        m_gridCols = new QSpinBox();
        m_gridCols->setRange(1, 64);
        m_gridCols->setValue(6);
        generalForm->addRow("Default grid columns:", m_gridCols);

        m_gridRows = new QSpinBox();
        m_gridRows->setRange(1, 64);
        m_gridRows->setValue(4);
        generalForm->addRow("Default grid rows:", m_gridRows);

        m_autostart = new QCheckBox("Launch DivvyGrid automatically on login");
        m_autostart->setChecked(isAutostartEnabled());
        generalForm->addRow("", m_autostart);

        m_resizeOverlapping = new QCheckBox("Resize overlapping windows to make room");
        m_resizeOverlapping->setChecked(true);
        generalForm->addRow("", m_resizeOverlapping);

        m_hotCorner = new QComboBox();
        m_hotCorner->addItem("None (keyboard shortcut only)", "none");
        m_hotCorner->addItem("Top-left", "topLeft");
        m_hotCorner->addItem("Top-right", "topRight");
        m_hotCorner->addItem("Bottom-left", "bottomLeft");
        m_hotCorner->addItem("Bottom-right", "bottomRight");
        generalForm->addRow("Mouse hot corner:", m_hotCorner);
        auto *hotCornerHint = new QLabel("Push the cursor into this screen corner to open the overlay - no keyboard needed.");
        hotCornerHint->setStyleSheet("color: gray; font-size: 11px;");
        hotCornerHint->setWordWrap(true);
        generalForm->addRow("", hotCornerHint);

        outer->addWidget(generalBox);

        // --- Per-monitor overrides ---
        auto *monitorBox = new QGroupBox("Per-Monitor Grid Overrides");
        auto *monitorLayout = new QVBoxLayout(monitorBox);
        buildMonitorRows(monitorLayout);
        outer->addWidget(monitorBox);

        // --- Buttons ---
        auto *btnRow = new QHBoxLayout();
        m_status = new QLabel();
        btnRow->addWidget(m_status);
        btnRow->addStretch();
        auto *saveBtn = new QPushButton("Save");
        auto *saveRestartBtn = new QPushButton("Save && Restart DivvyGrid");
        auto *quitBtn = new QPushButton("Quit DivvyGrid");
        auto *closeBtn = new QPushButton("Close");
        btnRow->addWidget(saveBtn);
        btnRow->addWidget(saveRestartBtn);
        btnRow->addWidget(quitBtn);
        btnRow->addWidget(closeBtn);
        outer->addLayout(btnRow);

        connect(saveBtn, &QPushButton::clicked, this, [this]() { save(false); });
        connect(saveRestartBtn, &QPushButton::clicked, this, [this]() { save(true); });
        connect(quitBtn, &QPushButton::clicked, this, [this]() {
            // "$"-anchored: an unanchored pattern also matches this settings app's own
            // "/.local/bin/divvygrid-settings" command line (prefix match) and would kill it
            QProcess::execute("pkill", {"-f", QDir::homePath() + "/.local/bin/divvygrid$"});
            m_status->setText("DivvyGrid daemon stopped.");
        });
        connect(closeBtn, &QPushButton::clicked, this, &QWidget::close);

        loadFromDisk();
        updateCompactEnabled();
        resize(460, 640);
    }

private:
    QComboBox *m_mode;
    QSpinBox *m_compactWidth;
    QSpinBox *m_compactHeight;
    QCheckBox *m_compactAtCursor;
    QSpinBox *m_gap;
    QKeySequenceEdit *m_shortcut;
    QSpinBox *m_gridCols;
    QSpinBox *m_gridRows;
    QCheckBox *m_autostart;
    QCheckBox *m_resizeOverlapping;
    QComboBox *m_hotCorner;
    QLabel *m_status;
    QVector<MonitorRow> m_monitorRows;

    void buildMonitorRows(QVBoxLayout *parent) {
        const auto screens = QGuiApplication::screens();
        if (screens.isEmpty()) {
            parent->addWidget(new QLabel("No connected monitors detected."));
            return;
        }
        for (QScreen *screen : screens) {
            MonitorRow row;
            row.name = screen->name();

            auto *rowWidget = new QWidget();
            auto *rowLayout = new QHBoxLayout(rowWidget);
            rowLayout->setContentsMargins(0, 0, 0, 0);

            const QRect geo = screen->geometry();
            row.enable = new QCheckBox(QString("%1 (%2x%3)")
                .arg(row.name)
                .arg(geo.width())
                .arg(geo.height()));
            rowLayout->addWidget(row.enable, 1);

            rowLayout->addWidget(new QLabel("cols:"));
            row.cols = new QSpinBox();
            row.cols->setRange(1, 64);
            row.cols->setValue(6);
            row.cols->setEnabled(false);
            rowLayout->addWidget(row.cols);

            rowLayout->addWidget(new QLabel("rows:"));
            row.rows = new QSpinBox();
            row.rows->setRange(1, 64);
            row.rows->setValue(4);
            row.rows->setEnabled(false);
            rowLayout->addWidget(row.rows);

            connect(row.enable, &QCheckBox::toggled, row.cols, &QSpinBox::setEnabled);
            connect(row.enable, &QCheckBox::toggled, row.rows, &QSpinBox::setEnabled);

            parent->addWidget(rowWidget);
            m_monitorRows.push_back(row);
        }
    }

    void updateCompactEnabled() {
        const bool compact = m_mode->currentData().toString() == "compact";
        m_compactWidth->setEnabled(compact);
        m_compactHeight->setEnabled(compact);
        m_compactAtCursor->setEnabled(compact);
    }

    void loadFromDisk() {
        QFile f(configPath());
        if (!f.exists() || !f.open(QIODevice::ReadOnly)) {
            // No config yet (or unreadable) - keep the built-in defaults already
            // set on the widgets above. Matches main.cpp's Config{} defaults.
            m_shortcut->setKeySequence(QKeySequence("Meta+Alt+D"));
            return;
        }
        const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
        f.close();
        if (!doc.isObject()) {
            m_shortcut->setKeySequence(QKeySequence("Meta+Alt+D"));
            return;
        }
        const QJsonObject obj = doc.object();

        const QString mode = obj.value("mode").toString("fullscreen");
        const int modeIdx = m_mode->findData(mode == "compact" ? "compact" : "fullscreen");
        m_mode->setCurrentIndex(modeIdx >= 0 ? modeIdx : 0);

        m_compactWidth->setValue(obj.value("compactWidth").toInt(480));
        m_compactHeight->setValue(obj.value("compactHeight").toInt(300));
        m_compactAtCursor->setChecked(obj.value("compactAtCursor").toBool(false));
        m_gap->setValue(obj.value("gap").toInt(8));
        m_gridCols->setValue(obj.value("gridCols").toInt(6));
        m_gridRows->setValue(obj.value("gridRows").toInt(4));
        m_resizeOverlapping->setChecked(obj.value("resizeOverlapping").toBool(true));

        const QString hotCorner = obj.value("hotCorner").toString("none");
        const int hotCornerIdx = m_hotCorner->findData(hotCorner);
        m_hotCorner->setCurrentIndex(hotCornerIdx >= 0 ? hotCornerIdx : 0);

        const QString shortcutStr = obj.value("shortcut").toString("Meta+Alt+D");
        QKeySequence seq(shortcutStr);
        m_shortcut->setKeySequence(seq.isEmpty() ? QKeySequence("Meta+Alt+D") : seq);

        if (obj.contains("monitors") && obj.value("monitors").isObject()) {
            const QJsonObject monitors = obj.value("monitors").toObject();
            for (MonitorRow &row : m_monitorRows) {
                if (!monitors.contains(row.name)) continue;
                const QJsonObject m = monitors.value(row.name).toObject();
                row.enable->setChecked(true);
                row.cols->setValue(m.value("gridCols").toInt(row.cols->value()));
                row.rows->setValue(m.value("gridRows").toInt(row.rows->value()));
            }
        }
    }

    void save(bool restart) {
        QDir().mkpath(QDir::homePath() + "/.config/divvygrid");

        QJsonObject obj;
        obj["mode"] = m_mode->currentData().toString();
        obj["compactWidth"] = m_compactWidth->value();
        obj["compactHeight"] = m_compactHeight->value();
        obj["compactAtCursor"] = m_compactAtCursor->isChecked();
        obj["gap"] = m_gap->value();

        QString shortcutStr = m_shortcut->keySequence().toString(QKeySequence::PortableText);
        if (shortcutStr.isEmpty()) shortcutStr = "Meta+Alt+D";
        obj["shortcut"] = shortcutStr;

        obj["gridCols"] = m_gridCols->value();
        obj["gridRows"] = m_gridRows->value();
        obj["resizeOverlapping"] = m_resizeOverlapping->isChecked();
        obj["hotCorner"] = m_hotCorner->currentData().toString();

        QJsonObject monitors;
        for (const MonitorRow &row : m_monitorRows) {
            if (!row.enable->isChecked()) continue;
            QJsonObject m;
            m["gridCols"] = row.cols->value();
            m["gridRows"] = row.rows->value();
            monitors[row.name] = m;
        }
        obj["monitors"] = monitors;

        setAutostartEnabled(m_autostart->isChecked());

        QFile f(configPath());
        if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            QMessageBox::warning(this, "Save failed",
                "Could not write " + configPath());
            return;
        }
        f.write(QJsonDocument(obj).toJson(QJsonDocument::Indented));
        f.close();

        m_status->setText("Saved.");
        QTimer::singleShot(3000, m_status, [this]() { m_status->clear(); });

        if (restart) restartDaemon();
    }

    void restartDaemon() {
        const QString binPath = QDir::homePath() + "/.local/bin/divvygrid";
        // "$"-anchored, see the Quit button handler for why
        QProcess::execute("pkill", {"-f", binPath + "$"});
        // pkill is async; give the old process a moment to actually exit before
        // relaunching, same caveat as the manual deploy steps in CLAUDE.md.
        QTimer::singleShot(700, this, [binPath]() {
            QProcess::startDetached(binPath, {});
        });
        m_status->setText("Saved. Restarting daemon...");
    }
};

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);
    QGuiApplication::setDesktopFileName(QStringLiteral("divvygrid-settings"));
    SettingsWindow w;
    w.show();
    return app.exec();
}

#include "settings_main.moc"
