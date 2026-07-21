import QtQuick
import org.kde.kwin

// Global shortcut registration. Rebind from System Settings → Shortcuts if the
// default Meta+Alt+D doesn't suit.

Item {

    signal showOverlay()
    signal expandToGap()

    ShortcutHandler {
        name: "VibeTiles: Show overlay"
        text: "VibeTiles: Show overlay"
        sequence: "Meta+Alt+D"
        onActivated: {
            showOverlay();
        }
    }

    ShortcutHandler {
        name: "VibeTiles: Expand to gap"
        text: "VibeTiles: Expand to gap"
        sequence: "Meta+Alt+E"
        onActivated: {
            expandToGap();
        }
    }
}
