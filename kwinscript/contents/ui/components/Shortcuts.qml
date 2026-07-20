import QtQuick
import org.kde.kwin

// Global shortcut registration. Rebind from System Settings → Shortcuts if the
// default Meta+Alt+D doesn't suit.

Item {

    signal showOverlay()

    ShortcutHandler {
        name: "DivvyGrid: Show overlay"
        text: "DivvyGrid: Show overlay"
        sequence: "Meta+Alt+D"
        onActivated: {
            showOverlay();
        }
    }
}
