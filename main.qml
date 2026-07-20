import QtQuick
import QtQuick.Window
import org.kde.layershell 1.0 as LayerShellQt

Window {
    id: root
    visible: false
    color: "transparent"
    flags: Qt.FramelessWindowHint

    LayerShellQt.Window.layer: LayerShellQt.Window.LayerOverlay
    LayerShellQt.Window.keyboardInteractivity: LayerShellQt.Window.KeyboardInteractivityOnDemand
    LayerShellQt.Window.exclusionZone: -1
    LayerShellQt.Window.anchors: LayerShellQt.Window.AnchorTop | LayerShellQt.Window.AnchorBottom | LayerShellQt.Window.AnchorLeft | LayerShellQt.Window.AnchorRight

    // this Window object is hidden and reused rather than recreated on every toggle, so any
    // leftover Shift-held state from a previous session (e.g. Shift released while the
    // overlay was already closing, missing the key-release event) must be cleared here -
    // otherwise the grid opens pre-doubled until Shift is tapped once to "reset" it
    onVisibleChanged: if (visible) root.shiftHeld = false;

    property bool dragging: false
    property point dragStart: Qt.point(0, 0)
    property point dragCurrent: Qt.point(0, 0)
    // true while a drag-triggered (as opposed to hotkey-triggered) activation is live —
    // the preview then tracks controller.externalCursorX/Y instead of real mouse events
    property bool externalMode: false

    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    // gridCols/gridRows/overlayMode/compactWidth/compactHeight/targetScreenWidth/targetScreenHeight
    // come from C++ context properties, loaded from ~/.config/divvygrid/config.json

    // holding Shift temporarily doubles the grid resolution for finer placement, without
    // touching the configured gridCols/gridRows - all cell math below uses effCols/effRows
    // instead of the raw context properties so this applies everywhere live
    property bool shiftHeld: false
    property int effCols: shiftHeld ? gridCols * 2 : gridCols
    property int effRows: shiftHeld ? gridRows * 2 : gridRows

    property bool isCompact: overlayMode === "compact"
    // canvas always represents the screen's available (work) area, not the full output -
    // otherwise the grid would cover space reserved by panels/taskbars and let windows
    // get placed underneath them
    property real canvasWidth: isCompact ? Math.min(compactWidth, availWidth) : availWidth
    property real canvasHeight: isCompact ? Math.min(compactHeight, availHeight) : availHeight
    // root-local (relative to this window, which still spans the full output) offset of
    // the available area's left/top edge
    property real availLocalX: availX - screenX
    property real availLocalY: availY - screenY
    // compact + drag-triggered: spawn the canvas centered on the cursor instead of the screen,
    // clamped to the available area so it can't render underneath a panel
    property real canvasX: (isCompact && controller.spawnAtCursor)
        ? clamp((controller.externalCursorX - screenX) - canvasWidth / 2, availLocalX, availLocalX + availWidth - canvasWidth)
        : availLocalX + (availWidth - canvasWidth) / 2
    property real canvasY: (isCompact && controller.spawnAtCursor)
        ? clamp((controller.externalCursorY - screenY) - canvasHeight / 2, availLocalY, availLocalY + availHeight - canvasHeight)
        : availLocalY + (availHeight - canvasHeight) / 2

    // maps a point in canvas-local coordinates to the target screen's absolute pixel coordinates
    property real scaleX: availWidth / canvasWidth
    property real scaleY: availHeight / canvasHeight

    function snapFloorX(px) {
        const cellW = canvasWidth / effCols;
        const idx = Math.floor(px / cellW);
        return Math.max(0, Math.min(effCols, idx)) * cellW;
    }
    function snapCeilX(px) {
        const cellW = canvasWidth / effCols;
        const idx = Math.ceil(px / cellW);
        return Math.max(0, Math.min(effCols, idx)) * cellW;
    }
    function snapFloorY(py) {
        const cellH = canvasHeight / effRows;
        const idx = Math.floor(py / cellH);
        return Math.max(0, Math.min(effRows, idx)) * cellH;
    }
    function snapCeilY(py) {
        const cellH = canvasHeight / effRows;
        const idx = Math.ceil(py / cellH);
        return Math.max(0, Math.min(effRows, idx)) * cellH;
    }
    // raw (unsnapped) drag rectangle — used for live preview so the selection always
    // starts exactly where the press happened, instead of jumping to the nearest gridline
    function rawRect() {
        const x1 = Math.min(dragStart.x, dragCurrent.x);
        const y1 = Math.min(dragStart.y, dragCurrent.y);
        const x2 = Math.max(dragStart.x, dragCurrent.x);
        const y2 = Math.max(dragStart.y, dragCurrent.y);
        return Qt.rect(x1, y1, x2 - x1, y2 - y1);
    }
    // grid-snapped rectangle — only used to compute the final placement on release.
    // Expands outward (floor the low edge, ceil the high edge) so every cell the raw
    // drag touched, even partially, ends up included — rounding to the nearest line
    // instead would drop the start/end cell whenever the press/release landed in the
    // "wrong" half of it.
    function snappedRect() {
        const x1 = snapFloorX(Math.min(dragStart.x, dragCurrent.x));
        const y1 = snapFloorY(Math.min(dragStart.y, dragCurrent.y));
        const x2 = snapCeilX(Math.max(dragStart.x, dragCurrent.x));
        const y2 = snapCeilY(Math.max(dragStart.y, dragCurrent.y));
        return Qt.rect(x1, y1, x2 - x1, y2 - y1);
    }

    // column/row index bounds (end-exclusive) of the grid cells the current raw drag
    // touches, even partially - same floor/ceil-outward logic as snappedRect(), just kept
    // in cell-index space instead of pixels so individual cells can be highlighted
    function computeSelBounds() {
        const cellW = canvasWidth / effCols;
        const cellH = canvasHeight / effRows;
        const r = root.rawRect();
        return {
            c1: Math.max(0, Math.min(effCols, Math.floor(r.x / cellW))),
            c2: Math.max(0, Math.min(effCols, Math.ceil((r.x + r.width) / cellW))),
            r1: Math.max(0, Math.min(effRows, Math.floor(r.y / cellH))),
            r2: Math.max(0, Math.min(effRows, Math.ceil((r.y + r.height) / cellH)))
        };
    }
    property var selBounds: root.dragging ? root.computeSelBounds() : null

    // converts a controller.externalCursorX/Y pair (absolute global screen pixels) to
    // canvas-local coordinates, the same frame dragStart/dragCurrent live in
    function externalCanvasPoint() {
        return Qt.point(
            controller.externalCursorX - screenX - root.canvasX,
            controller.externalCursorY - screenY - root.canvasY
        );
    }

    // shared by the real MouseArea's onReleased and the externally-driven
    // externalDragFinished handler — the release-time commit/cancel logic must stay identical
    function finishDrag() {
        root.dragging = false;
        const r = root.snappedRect();
        if (r.width < 10 || r.height < 10) {
            controller.cancel();
            return;
        }
        controller.commit(
            Math.round(availX + r.x * root.scaleX),
            Math.round(availY + r.y * root.scaleY),
            Math.round(r.width * root.scaleX),
            Math.round(r.height * root.scaleY)
        );
    }

    Connections {
        target: controller
        function onExternalDragStarted() {
            root.externalMode = true;
            const p = root.externalCanvasPoint();
            root.dragStart = p;
            root.dragCurrent = p;
            root.dragging = true;
        }
        function onExternalCursorChanged() {
            if (root.externalMode && root.dragging) root.dragCurrent = root.externalCanvasPoint();
        }
        function onExternalDragFinished() {
            if (!root.dragging) return;
            root.dragCurrent = root.externalCanvasPoint();
            root.finishDrag();
            root.externalMode = false;
        }
    }

    // background: click here (outside the canvas, only relevant in compact mode) cancels
    MouseArea {
        anchors.fill: parent
        onClicked: controller.cancel()
    }

    Rectangle {
        id: canvas
        x: root.canvasX
        y: root.canvasY
        width: root.canvasWidth
        height: root.canvasHeight
        color: root.isCompact ? "#cc1e1e1e" : "#22000000"
        border.color: root.isCompact ? "#55ffffff" : "transparent"
        border.width: root.isCompact ? 1 : 0
        radius: root.isCompact ? 6 : 0

        Repeater {
            model: root.effCols - 1
            Rectangle {
                x: (index + 1) * (canvas.width / root.effCols)
                y: 0
                width: 1
                height: canvas.height
                color: "#33ffffff"
            }
        }
        Repeater {
            model: root.effRows - 1
            Rectangle {
                x: 0
                y: (index + 1) * (canvas.height / root.effRows)
                width: canvas.width
                height: 1
                color: "#33ffffff"
            }
        }

        // highlights each individual grid cell the current selection covers, distinct from
        // the freeform preview rectangle below - makes it obvious exactly which cells will
        // be occupied, since the preview box tracks the raw (unsnapped) drag instead
        Repeater {
            model: root.selBounds ? root.effCols * root.effRows : 0
            Rectangle {
                property int col: index % root.effCols
                property int row: Math.floor(index / root.effCols)
                visible: root.selBounds
                    && col >= root.selBounds.c1 && col < root.selBounds.c2
                    && row >= root.selBounds.r1 && row < root.selBounds.r2
                x: col * (canvas.width / root.effCols)
                y: row * (canvas.height / root.effRows)
                width: canvas.width / root.effCols
                height: canvas.height / root.effRows
                color: "#4400aaff"
            }
        }

        Rectangle {
            visible: root.dragging
            color: "#5500aaff"
            border.color: "white"
            border.width: 2
            // gap is defined in real screen pixels (see main.cpp's applyResize); shrink
            // the preview by the same amount, mapped back into canvas-local pixels, so
            // what's shown during the drag matches the final gapped window placement
            property real gapX: windowGap / root.scaleX
            property real gapY: windowGap / root.scaleY
            property rect r: root.rawRect()
            x: r.x + gapX / 2
            y: r.y + gapY / 2
            width: Math.max(0, r.width - gapX)
            height: Math.max(0, r.height - gapY)
        }

        MouseArea {
            anchors.fill: parent
            onPressed: (mouse) => {
                root.pickerOpen = false;
                root.dragStart = Qt.point(mouse.x, mouse.y);
                root.dragCurrent = root.dragStart;
                root.dragging = true;
            }
            onPositionChanged: (mouse) => {
                if (root.dragging) root.dragCurrent = Qt.point(mouse.x, mouse.y);
            }
            onReleased: (mouse) => {
                if (!root.dragging) return;
                root.dragCurrent = Qt.point(mouse.x, mouse.y);
                root.finishDrag();
            }
        }
    }

    property bool pickerOpen: false

    // compact mode only: floating bar above the grid showing which window is about to be
    // resized, so the user isn't guessing. Click to expand a picker and retarget it.
    Rectangle {
        id: titleBar
        visible: root.isCompact && targetTitle.length > 0
        width: Math.min(canvas.width, titleRow.implicitWidth + 24)
        height: 32
        x: canvas.x + (canvas.width - width) / 2
        // prefer sitting above the grid; if there isn't enough room in the available area
        // (e.g. the box spawned right at the top of the screen), drop below it instead of
        // clamping in place, which would overlap/eat into the grid's top edge
        y: (canvas.y - height - 8 >= root.availLocalY)
            ? canvas.y - height - 8
            : canvas.y + canvas.height + 8
        z: 30
        color: "#dd1e1e1e"
        radius: 6
        border.color: "#55ffffff"
        border.width: 1

        Row {
            id: titleRow
            anchors.centerIn: parent
            spacing: 8
            Image {
                source: targetIconName.length > 0 ? "image://wicon/" + targetIconName : ""
                width: 18
                height: 18
                fillMode: Image.PreserveAspectFit
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: targetTitle
                color: "white"
                font.pixelSize: 13
                elide: Text.ElideRight
                width: Math.min(implicitWidth, 240)
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.pickerOpen ? "▴" : "▾"
                color: "#aaffffff"
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.pickerOpen = !root.pickerOpen
        }
    }

    // expands below the title bar when clicked - lets the user pick a different window on
    // this screen than the one that was active/dragged when the overlay was triggered
    Rectangle {
        id: pickerPanel
        visible: root.isCompact && root.pickerOpen && windowList.length > 0
        x: titleBar.x
        y: titleBar.y + titleBar.height + 4
        width: titleBar.width
        height: Math.min(pickerColumn.implicitHeight + 12, 220)
        z: 31
        color: "#dd1e1e1e"
        radius: 6
        border.color: "#55ffffff"
        border.width: 1
        clip: true

        Flickable {
            anchors.fill: parent
            anchors.margins: 6
            contentWidth: width
            contentHeight: pickerColumn.implicitHeight
            clip: true

            Column {
                id: pickerColumn
                width: parent.width
                spacing: 2

                Repeater {
                    model: windowList
                    // one delegate per window, with an optional screen-group header/divider
                    // above it whenever this entry's screen differs from the previous one -
                    // windowList is pre-sorted (current screen first) so groups are contiguous
                    delegate: Column {
                        width: pickerColumn.width
                        spacing: 2
                        property bool isNewGroup: index === 0 || windowList[index - 1].screen !== modelData.screen

                        Rectangle {
                            visible: parent.isNewGroup && index !== 0
                            width: parent.width
                            height: 1
                            color: "#33ffffff"
                        }
                        Text {
                            visible: parent.isNewGroup
                            text: modelData.screen === currentScreenName ? "This Display" : modelData.screen
                            color: "#88ffffff"
                            font.pixelSize: 10
                            font.bold: true
                            topPadding: index === 0 ? 0 : 4
                            bottomPadding: 2
                        }

                        Rectangle {
                            width: parent.width
                            height: 28
                            radius: 4
                            color: entryMouse.containsMouse ? "#33ffffff" : "transparent"

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 6
                                spacing: 8
                                Image {
                                    source: modelData.icon.length > 0 ? "image://wicon/" + modelData.icon : ""
                                    width: 16
                                    height: 16
                                    fillMode: Image.PreserveAspectFit
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: modelData.title
                                    color: "white"
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                    width: pickerColumn.width - 40
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: entryMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    controller.selectWindow(modelData.id, modelData.title, modelData.icon);
                                    root.pickerOpen = false;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: controller.cancel()
        // holding Shift temporarily doubles the grid resolution (see effCols/effRows) for
        // finer placement without changing the configured grid size
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Shift) root.shiftHeld = true;
        }
        Keys.onReleased: (event) => {
            if (event.key === Qt.Key_Shift) root.shiftHeld = false;
        }
    }
}
