import QtQuick
import org.kde.kwin

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
