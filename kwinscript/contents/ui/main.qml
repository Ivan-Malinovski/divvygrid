import QtQuick
import org.kde.kwin
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore

import "components" as Components

// Declarative KWin script port of the DivvyGrid daemon (see ../../../main.cpp /
// ../../../main.qml in the repo root for the standalone-app version this is replacing).
// Runs entirely inside kwin_wayland: Workspace.* is the same privileged API the daemon
// used to reach only by injecting throwaway scripts over D-Bus, now available directly
// and synchronously, so all the async report-back plumbing (AppService/Controller,
// queryWindowList, queryWindowInfo, ...) collapses into plain function calls.
//
// Root must be PlasmaCore.Dialog, not a plain QtQuick Window - a bare Window with
// interactive flags (Qt.Popup etc) gets wrapped by the declarative-script host's own
// dialog presentation and logs "QML Dialog: trying to show an empty dialog" without
// ever actually appearing (confirmed live; this is the same pattern kzones/main.qml and
// mousetiler/OverlayTiler.qml use for their own full-screen overlays).

PlasmaCore.Dialog {
    id: root

    location: PlasmaCore.Types.Desktop
    backgroundHints: PlasmaCore.Types.NoBackground
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    visible: false

    // ---- config, read from contents/config/main.xml via KWin.readConfig() ----
    property int gridCols: 6
    property int gridRows: 4
    property string overlayMode: "fullscreen" // "fullscreen" | "compact"
    property int compactWidth: 480
    property int compactHeight: 300
    property int windowGap: 8
    property bool resizeOverlapping: true
    property bool compactAtCursor: false
    property string hotCorner: "none"
    // when true, any native window drag auto-shows a small top-center single-cell picker
    // after the window has moved past a threshold, no shortcut needed - modeled on
    // KZones/MouseTiler's automatic drag-triggered zone overlays. Opt-in since it changes
    // the feel of every plain window move, not just shortcut-driven placements.
    property bool dragAutoTrigger: false
    // per-output {gridCols, gridRows} overrides, keyed by output name (e.g. "DP-2"),
    // parsed from the monitorsJson config entry
    property var monitorOverrides: ({})
    // grid size actually in effect for the screen the overlay is showing on - the
    // per-monitor override if one matches targetScreenObj.name, else the defaults above.
    // effCols/effRows (the shift-doubling multiplier) are derived from these, not
    // directly from gridCols/gridRows, so overrides apply everywhere sizing does.
    property int activeGridCols: gridCols
    property int activeGridRows: gridRows

    // combo-box-backed entries are Int in kcfg, not String - a plain QComboBox's
    // auto-bindable property is currentIndex, so a String entry would just store the
    // index as text instead of matching by name (confirmed live - this silently broke
    // mode-switching). Map index -> name here to match config.ui's item order.
    readonly property var modeNames: ["fullscreen", "compact"]
    readonly property var hotCornerNames: ["none", "topLeft", "topRight", "bottomLeft", "bottomRight"]

    function loadConfig() {
        gridCols = KWin.readConfig("gridCols", 6);
        gridRows = KWin.readConfig("gridRows", 4);
        overlayMode = modeNames[KWin.readConfig("mode", 0)] || "fullscreen";
        compactWidth = KWin.readConfig("compactWidth", 480);
        compactHeight = KWin.readConfig("compactHeight", 300);
        windowGap = KWin.readConfig("gap", 8);
        resizeOverlapping = KWin.readConfig("resizeOverlapping", true);
        compactAtCursor = KWin.readConfig("compactAtCursor", false);
        hotCorner = hotCornerNames[KWin.readConfig("hotCorner", 0)] || "none";
        dragAutoTrigger = KWin.readConfig("dragAutoTrigger", false);
        try {
            monitorOverrides = JSON.parse(KWin.readConfig("monitorsJson", "{}"));
        } catch (e) {
            monitorOverrides = {};
        }
    }

    Component.onCompleted: {
        root.loadConfig();
        const wins = Workspace.stackingOrder;
        for (let i = 0; i < wins.length; i++) root.hookWindow(wins[i]);
    }

    // ---- captured at show()-time, used throughout this activation ----
    property var targetWindow: null
    property string targetTitle: ""
    property string targetIconName: ""
    property var targetScreenObj: null
    // full output geometry - this Window itself spans it
    property rect screenGeo: Qt.rect(0, 0, 1920, 1080)
    // work area (screen geometry minus panels/docks) - KWin.PlacementArea is the
    // clientArea option that actually excludes panel struts (confirmed empirically for
    // the daemon version - see CLAUDE.md gotchas); everything below stays within this
    property rect availGeo: Qt.rect(0, 0, 1920, 1080)
    property point spawnCursorPos: Qt.point(0, 0)
    property var windowList: []

    x: screenGeo.x
    y: screenGeo.y
    width: screenGeo.width
    height: screenGeo.height

    property bool dragging: false
    property point dragStart: Qt.point(0, 0)
    property point dragCurrent: Qt.point(0, 0)
    // true while the currently-shown overlay was triggered by the shortcut firing mid a
    // native window drag (see "drag-triggered activation" below), as opposed to a plain
    // hotkey press - the selection then tracks nativeDragWindow's live position instead of
    // this overlay's own MouseArea, which never receives real pointer events during a
    // native interactive move (the compositor keeps that grab with the dragged window).
    property bool dragTriggered: false

    // true while the currently-shown overlay is the auto-trigger-on-drag picker (see
    // "auto-trigger on drag" below) - a small top-center single-cell hover picker, distinct
    // from both the shortcut-driven grid and dragTriggered's cursor-following box.
    property bool autoMode: false

    // holding Shift temporarily doubles the grid resolution for finer placement -
    // all cell math below uses effCols/effRows instead of the raw config values
    property bool shiftHeld: false
    property int effCols: shiftHeld ? activeGridCols * 2 : activeGridCols
    property int effRows: shiftHeld ? activeGridRows * 2 : activeGridRows

    property bool isCompact: overlayMode === "compact" || root.autoMode
    property real availLocalX: availGeo.x - screenGeo.x
    property real availLocalY: availGeo.y - screenGeo.y
    property real canvasWidth: isCompact ? Math.min(compactWidth, availGeo.width) : availGeo.width
    property real canvasHeight: isCompact ? Math.min(compactHeight, availGeo.height) : availGeo.height
    // drag-triggered activations always spawn the compact box at the cursor, regardless of
    // the compactAtCursor setting - it's inherently about following the mouse mid-drag.
    // autoMode overrides this the other way: it always sits fixed top-center (see below),
    // never follows the cursor, so it doesn't jump around as the dragged window moves.
    property bool effectiveCompactAtCursor: (compactAtCursor || dragTriggered) && !root.autoMode
    property real canvasX: root.autoMode
        ? availLocalX + (availGeo.width - canvasWidth) / 2
        : (isCompact && effectiveCompactAtCursor)
            ? clamp((spawnCursorPos.x - screenGeo.x) - canvasWidth / 2, availLocalX, availLocalX + availGeo.width - canvasWidth)
            : availLocalX + (availGeo.width - canvasWidth) / 2
    property real canvasY: root.autoMode
        ? availLocalY + 24
        : (isCompact && effectiveCompactAtCursor)
            ? clamp((spawnCursorPos.y - screenGeo.y) - canvasHeight / 2, availLocalY, availLocalY + availGeo.height - canvasHeight)
            : availLocalY + (availGeo.height - canvasHeight) / 2
    property real scaleX: availGeo.width / canvasWidth
    property real scaleY: availGeo.height / canvasHeight

    property bool pickerOpen: false

    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    // ---- show / hide ----

    // the output whose geometry contains the given point, falling back to activeScreen -
    // the overlay should follow the mouse to whichever monitor the user is pointing at,
    // not wherever the target window currently happens to sit (see daemon's
    // QGuiApplication::screenAt(gCursorPos) - same intent, ported here)
    function screenAt(point) {
        const screens = Workspace.screens;
        for (let i = 0; i < screens.length; i++) {
            const g = screens[i].geometry;
            if (point.x >= g.x && point.x < g.x + g.width && point.y >= g.y && point.y < g.y + g.height) {
                return screens[i];
            }
        }
        return Workspace.activeScreen;
    }

    // forcedTarget: when set (a window object), this activation is drag-triggered - target
    // that window instead of Workspace.activeWindow and seed the selection at the window's
    // current native-drag position instead of starting with no selection.
    function show(forcedTarget) {
        root.loadConfig();

        const isDragTriggered = !!forcedTarget;
        root.dragTriggered = isDragTriggered;
        // compact mode's small, cursor-centered box makes the anchor-point restriction
        // (the selection always has to include wherever the cursor was when the shortcut
        // fired) much more cramped than in fullscreen, where there's enough room to reach
        // most layouts anyway - so drag-triggered activations always use fullscreen,
        // regardless of the configured mode.
        if (isDragTriggered) root.overlayMode = "fullscreen";

        // capture the window to act on before our own popup steals activation - mirrors
        // the daemon's captureActiveWindow(), just synchronous now
        targetWindow = isDragTriggered ? forcedTarget : Workspace.activeWindow;
        targetTitle = targetWindow ? (targetWindow.caption || "") : "";
        targetIconName = targetWindow && targetWindow.resourceClass ? targetWindow.resourceClass.toString() : "";
        spawnCursorPos = Workspace.cursorPos;

        targetScreenObj = screenAt(spawnCursorPos);
        screenGeo = targetScreenObj.geometry;
        availGeo = Workspace.clientArea(KWin.PlacementArea, targetScreenObj, Workspace.currentDesktop);

        const override = monitorOverrides[targetScreenObj.name];
        activeGridCols = (override && override.gridCols > 0) ? override.gridCols : gridCols;
        activeGridRows = (override && override.gridRows > 0) ? override.gridRows : gridRows;

        if (isCompact) refreshWindowList();

        root.shiftHeld = false;
        root.pickerOpen = false;
        root.visible = true;
        // PlasmaQuick::Dialog's prototype is QQuickWindow, so it has requestActivate(), but
        // these script-owned windows never reliably receive real keyboard focus regardless
        // (confirmed live: Escape/Keys.onEscapePressed never fires even with this call) -
        // Shift is read off mouse-event modifiers instead (see canvas MouseArea) which
        // sidesteps the problem; Escape has no such workaround, so cancel is right-click.
        root.requestActivate();
        keyHandler.forceActiveFocus();

        if (isDragTriggered) {
            const p = root.externalCanvasPoint();
            root.dragStart = p;
            root.dragCurrent = p;
            root.dragging = true;
        } else {
            root.dragging = false;
        }
    }

    function hide() {
        root.visible = false;
        root.dragging = false;
        root.dragTriggered = false;
        root.autoMode = false;
        root.autoDragPending = false;
        root.autoAnchored = false;
    }

    function toggle() {
        if (root.visible) {
            hide();
        } else if (root.nativeDragActive && root.nativeDragWindow) {
            root.show(root.nativeDragWindow);
        } else {
            root.show(null);
        }
    }

    // ---- drag-triggered activation ----
    //
    // Holding the shortcut mid a native window drag (moving/resizing a window with the
    // mouse) retargets the overlay at that window instead of the current active window,
    // following the mouse for the rest of that native drag. Ported from the daemon's
    // persistent injected "drag watcher" KWin script + AppService::dragTick D-Bus relay -
    // in-script this is just interactiveMoveResizeStarted/Stepped/Finished hooked directly
    // on window objects, no D-Bus or second script needed.
    property var nativeDragWindow: null
    property bool nativeDragActive: false

    // canvas-local point matching Workspace.cursorPos, the same frame dragStart/dragCurrent
    // live in - used to seed and update the selection during a drag-triggered activation,
    // since this overlay's own MouseArea gets no real pointer events during a native drag.
    function externalCanvasPoint() {
        return Qt.point(
            Workspace.cursorPos.x - screenGeo.x - root.canvasX,
            Workspace.cursorPos.y - screenGeo.y - root.canvasY
        );
    }

    // ---- auto-trigger on drag ----
    //
    // With dragAutoTrigger enabled, any native window drag (no shortcut needed) shows a
    // small top-center picker once the window has moved past a distance threshold - avoids
    // flashing the overlay on a plain click-to-focus or tiny nudge. There's only one tracked
    // point available (the native drag position - our own MouseArea gets no events during a
    // native move), so a real press-drag-release rectangle gesture isn't possible the way
    // the shortcut-driven grid does it. Instead: the picker starts with nothing selected,
    // and the moment the cursor first crosses into the picker's bounds, that point becomes
    // a pinned anchor - continuing to drag from there grows a normal rectangle selection
    // (reusing dragging/rawRect/computeSelBounds/finishDrag as-is) between that anchor and
    // the live cursor position, same visual as the shortcut-driven grid.
    property bool autoDragPending: false
    property point autoDragStartPos: Qt.point(0, 0)
    readonly property int autoDragThreshold: 24
    // true once the cursor has crossed into the picker at least once this drag and an
    // anchor corner has been pinned - before that, nothing is selected/highlighted yet
    property bool autoAnchored: false

    function pointInCanvas(p) {
        return p.x >= 0 && p.x <= canvasWidth && p.y >= 0 && p.y <= canvasHeight;
    }

    // forcedTarget is always set here (called only from onNativeDragStepped once the
    // threshold trips) - unlike show(), there's no "no target" case to handle.
    function showAuto(win) {
        root.loadConfig();
        root.dragTriggered = false;
        root.autoMode = true;
        root.autoAnchored = false;
        root.overlayMode = "compact";

        targetWindow = win;
        targetTitle = "";
        targetIconName = "";
        spawnCursorPos = Workspace.cursorPos;

        targetScreenObj = screenAt(spawnCursorPos);
        screenGeo = targetScreenObj.geometry;
        availGeo = Workspace.clientArea(KWin.PlacementArea, targetScreenObj, Workspace.currentDesktop);

        const override = monitorOverrides[targetScreenObj.name];
        activeGridCols = (override && override.gridCols > 0) ? override.gridCols : gridCols;
        activeGridRows = (override && override.gridRows > 0) ? override.gridRows : gridRows;

        root.shiftHeld = false;
        root.pickerOpen = false;
        root.dragging = false;
        root.visible = true;
        root.requestActivate();
        root.dragCurrent = root.externalCanvasPoint();
    }

    function onNativeDragStarted(win) {
        root.nativeDragWindow = win;
        root.nativeDragActive = true;
        if (root.dragAutoTrigger && !root.visible && win.normalWindow) {
            root.autoDragPending = true;
            root.autoDragStartPos = Workspace.cursorPos;
        }
    }

    function onNativeDragStepped(win) {
        if (win !== root.nativeDragWindow) return;
        if (root.visible && root.dragTriggered && root.targetWindow === win) {
            root.dragCurrent = root.externalCanvasPoint();
            return;
        }
        if (root.autoDragPending && !root.visible) {
            const p = Workspace.cursorPos;
            const dx = p.x - root.autoDragStartPos.x, dy = p.y - root.autoDragStartPos.y;
            if (Math.sqrt(dx * dx + dy * dy) >= root.autoDragThreshold) {
                root.autoDragPending = false;
                root.showAuto(win);
            }
            return;
        }
        if (root.visible && root.autoMode && root.targetWindow === win) {
            // the picker is pinned to whichever screen the drag started on, but a drag
            // routinely crosses monitors - re-home it (geometry, work area, per-monitor grid
            // override) to follow the cursor's current screen, same as show()/showAuto()
            // compute it initially. Any in-progress anchor/selection is screen-local, so it
            // gets dropped and has to be re-picked on the new screen rather than translated.
            const curScreen = root.screenAt(Workspace.cursorPos);
            if (curScreen !== root.targetScreenObj) {
                root.targetScreenObj = curScreen;
                root.screenGeo = curScreen.geometry;
                root.availGeo = Workspace.clientArea(KWin.PlacementArea, curScreen, Workspace.currentDesktop);
                const override = root.monitorOverrides[curScreen.name];
                root.activeGridCols = (override && override.gridCols > 0) ? override.gridCols : root.gridCols;
                root.activeGridRows = (override && override.gridRows > 0) ? override.gridRows : root.gridRows;
                root.autoAnchored = false;
                root.dragging = false;
            }

            const p = root.externalCanvasPoint();
            root.dragCurrent = p;
            if (!root.autoAnchored && root.pointInCanvas(p)) {
                root.dragStart = p;
                root.autoAnchored = true;
                root.dragging = true;
            }
        }
    }

    function onNativeDragFinished(win) {
        if (win !== root.nativeDragWindow) return;
        root.nativeDragActive = false;
        root.nativeDragWindow = null;
        root.autoDragPending = false;
        if (root.visible && root.dragTriggered && root.targetWindow === win) {
            root.dragCurrent = root.externalCanvasPoint();
            root.finishDrag();
            return;
        }
        if (root.visible && root.autoMode && root.targetWindow === win) {
            root.dragCurrent = root.externalCanvasPoint();
            if (root.autoAnchored) {
                root.finishDrag();
            } else {
                // cursor never crossed into the picker this drag - nothing to commit,
                // the native move already applied itself, so just get out of the way
                hide();
            }
        }
    }

    function onNativeDragWindowClosed(win) {
        if (root.nativeDragWindow === win) {
            root.nativeDragActive = false;
            root.nativeDragWindow = null;
        }
        root.autoDragPending = false;
    }

    function hookWindow(win) {
        win.interactiveMoveResizeStarted.connect(() => root.onNativeDragStarted(win));
        win.interactiveMoveResizeStepped.connect(() => root.onNativeDragStepped(win));
        win.interactiveMoveResizeFinished.connect(() => root.onNativeDragFinished(win));
        win.closed.connect(() => root.onNativeDragWindowClosed(win));
    }

    // {id-less, direct object refs} list of every normal window across all monitors,
    // current-screen entries first (drives the compact title bar's window-switch picker)
    function refreshWindowList() {
        const targetName = targetScreenObj ? targetScreenObj.name : "";
        const wins = Workspace.stackingOrder;
        const result = [];
        for (let i = 0; i < wins.length; i++) {
            const w = wins[i];
            if (!w.normalWindow || w.minimized) continue;
            result.push({
                win: w,
                title: w.caption || "",
                icon: w.resourceClass ? w.resourceClass.toString() : "",
                screen: w.output ? w.output.name : ""
            });
        }
        result.sort((a, b) => {
            const aCur = a.screen === targetName ? 0 : 1;
            const bCur = b.screen === targetName ? 0 : 1;
            if (aCur !== bCur) return aCur - bCur;
            if (a.screen !== b.screen) return a.screen < b.screen ? -1 : 1;
            return a.title < b.title ? -1 : (a.title > b.title ? 1 : 0);
        });
        root.windowList = result;
    }

    function selectWindow(entry) {
        targetWindow = entry.win;
        targetTitle = entry.title;
        targetIconName = entry.icon;
        root.pickerOpen = false;
    }

    // ---- drag/snap math (ported as-is from the daemon's main.qml) ----

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
    function rawRect() {
        const x1 = Math.min(dragStart.x, dragCurrent.x);
        const y1 = Math.min(dragStart.y, dragCurrent.y);
        const x2 = Math.max(dragStart.x, dragCurrent.x);
        const y2 = Math.max(dragStart.y, dragCurrent.y);
        return Qt.rect(x1, y1, x2 - x1, y2 - y1);
    }
    function snappedRect() {
        const x1 = snapFloorX(Math.min(dragStart.x, dragCurrent.x));
        const y1 = snapFloorY(Math.min(dragStart.y, dragCurrent.y));
        const x2 = snapCeilX(Math.max(dragStart.x, dragCurrent.x));
        const y2 = snapCeilY(Math.max(dragStart.y, dragCurrent.y));
        return Qt.rect(x1, y1, x2 - x1, y2 - y1);
    }
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

    // ---- commit / overlap-resize (ported from main.cpp:477-547) ----

    function overlapRect(a, b) {
        const ix = Math.max(a.x, b.x), iy = Math.max(a.y, b.y);
        const ix2 = Math.min(a.x + a.width, b.x + b.width);
        const iy2 = Math.min(a.y + a.height, b.y + b.height);
        if (ix2 <= ix || iy2 <= iy) return null;
        return Qt.rect(ix, iy, ix2 - ix, iy2 - iy);
    }

    // shrinks any other window whose edge is fully covered by target's new rectangle, so
    // it retreats into the remaining space instead of ending up hidden underneath -
    // only handles a clean full-width/full-height edge slice, same as the daemon version
    function resizeOverlappingWindows(target) {
        const EPS = 24;
        const others = Workspace.stackingOrder;
        for (let j = 0; j < others.length; j++) {
            const ow = others[j];
            if (ow === root.targetWindow || ow.minimized || !ow.normalWindow) continue;
            const c = ow.frameGeometry;
            const ov = overlapRect(c, target);
            if (!ov) continue;
            let nr = null;
            if (ov.width >= c.width - EPS) {
                if (Math.abs(ov.y - c.y) <= EPS) {
                    nr = Qt.rect(c.x, ov.y + ov.height, c.width, (c.y + c.height) - (ov.y + ov.height));
                } else if (Math.abs((ov.y + ov.height) - (c.y + c.height)) <= EPS) {
                    nr = Qt.rect(c.x, c.y, c.width, ov.y - c.y);
                }
            }
            if (!nr && ov.height >= c.height - EPS) {
                if (Math.abs(ov.x - c.x) <= EPS) {
                    nr = Qt.rect(ov.x + ov.width, c.y, (c.x + c.width) - (ov.x + ov.width), c.height);
                } else if (Math.abs((ov.x + ov.width) - (c.x + c.width)) <= EPS) {
                    nr = Qt.rect(c.x, c.y, ov.x - c.x, c.height);
                }
            }
            if (nr && nr.width > 50 && nr.height > 50) {
                ow.setMaximize(false, false);
                ow.frameGeometry = nr;
            }
        }
    }

    function commit(x, y, w, h) {
        if (!targetWindow) {
            hide();
            return;
        }
        const inset = windowGap / 2;
        const gx = x + inset;
        const gy = y + inset;
        const gw = Math.max(50, w - windowGap);
        const gh = Math.max(50, h - windowGap);
        const rect = Qt.rect(Math.round(gx), Math.round(gy), Math.round(gw), Math.round(gh));
        targetWindow.setMaximize(false, false);
        targetWindow.frameGeometry = rect;
        if (resizeOverlapping) resizeOverlappingWindows(rect);
        hide();
    }

    function finishDrag() {
        root.dragging = false;
        const r = root.snappedRect();
        if (r.width < 10 || r.height < 10) {
            hide();
            return;
        }
        commit(
            availGeo.x + r.x * root.scaleX,
            availGeo.y + r.y * root.scaleY,
            r.width * root.scaleX,
            r.height * root.scaleY
        );
    }

    Components.Shortcuts {
        onShowOverlay: root.toggle()
    }

    Item {
        id: mainItem
        width: root.width
        height: root.height

    // mouse-only activation via KWin screen edges - same "push cursor into corner"
    // mechanism as the daemon's injected registerScreenEdge() watcher script, just
    // registered directly here instead of over D-Bus. Only one of these four is ever
    // enabled at once, driven by the hotCorner config value (see loadConfig()).
    ScreenEdgeHandler {
        edge: ScreenEdgeHandler.TopLeftEdge
        enabled: root.hotCorner === "topLeft"
        onActivated: root.toggle()
    }
    ScreenEdgeHandler {
        edge: ScreenEdgeHandler.TopRightEdge
        enabled: root.hotCorner === "topRight"
        onActivated: root.toggle()
    }
    ScreenEdgeHandler {
        edge: ScreenEdgeHandler.BottomLeftEdge
        enabled: root.hotCorner === "bottomLeft"
        onActivated: root.toggle()
    }
    ScreenEdgeHandler {
        edge: ScreenEdgeHandler.BottomRightEdge
        enabled: root.hotCorner === "bottomRight"
        onActivated: root.toggle()
    }

    Connections {
        target: Workspace
        function onWindowAdded(win) { root.hookWindow(win); }
    }

    // background: click here (outside the canvas, only relevant in compact mode) cancels
    MouseArea {
        anchors.fill: parent
        onClicked: root.hide()
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

        // highlights each individual grid cell the current selection covers, distinct
        // from the freeform preview rectangle below
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
            property real gapX: root.windowGap / root.scaleX
            property real gapY: root.windowGap / root.scaleY
            property rect r: root.rawRect()
            x: r.x + gapX / 2
            y: r.y + gapY / 2
            width: Math.max(0, r.width - gapX)
            height: Math.max(0, r.height - gapY)
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            // shift state is read straight off the mouse event's modifiers instead of a
            // Keys.onPressed handler - these script-owned windows don't reliably receive
            // real keyboard focus (confirmed live: forceActiveFocus() didn't fix it), but
            // pointer events always carry accurate modifier flags regardless of focus
            onPositionChanged: (mouse) => {
                root.shiftHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0;
                if (root.dragging) root.dragCurrent = Qt.point(mouse.x, mouse.y);
            }
            onPressed: (mouse) => {
                // Escape doesn't reach these script-owned windows (no reliable keyboard
                // focus - see requestActivate note in show()), so right-click cancels
                // instead, same intent as the daemon's Keys.onEscapePressed.
                if (mouse.button === Qt.RightButton) {
                    root.dragging = false;
                    root.hide();
                    return;
                }
                root.shiftHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0;
                root.pickerOpen = false;
                root.dragStart = Qt.point(mouse.x, mouse.y);
                root.dragCurrent = root.dragStart;
                root.dragging = true;
            }
            onReleased: (mouse) => {
                if (!root.dragging) return;
                root.dragCurrent = Qt.point(mouse.x, mouse.y);
                root.finishDrag();
            }
        }
    }

    // compact mode only: floating bar above the grid showing which window is about to be
    // resized. Click to expand a picker and retarget it.
    Rectangle {
        id: titleBar
        visible: root.isCompact && root.targetTitle.length > 0
        width: Math.min(canvas.width, titleRow.implicitWidth + 24)
        height: 32
        x: canvas.x + (canvas.width - width) / 2
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
            Kirigami.Icon {
                source: root.targetIconName
                width: 18
                height: 18
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.targetTitle
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

    // expands below the title bar - lets the user pick a different window, on any
    // monitor, than the one that was active when the overlay was triggered
    Rectangle {
        id: pickerPanel
        visible: root.isCompact && root.pickerOpen && root.windowList.length > 0
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
                    model: root.windowList
                    delegate: Column {
                        width: pickerColumn.width
                        spacing: 2
                        property bool isNewGroup: index === 0 || root.windowList[index - 1].screen !== modelData.screen

                        Rectangle {
                            visible: parent.isNewGroup && index !== 0
                            width: parent.width
                            height: 1
                            color: "#33ffffff"
                        }
                        Text {
                            visible: parent.isNewGroup
                            text: modelData.screen === (root.targetScreenObj ? root.targetScreenObj.name : "") ? "This Display" : modelData.screen
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
                                Kirigami.Icon {
                                    source: modelData.icon
                                    width: 16
                                    height: 16
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
                                onClicked: root.selectWindow(modelData)
                            }
                        }
                    }
                }
            }
        }
    }

    Item {
        id: keyHandler
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: root.hide()
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Shift) root.shiftHeld = true;
        }
        Keys.onReleased: (event) => {
            if (event.key === Qt.Key_Shift) root.shiftHeld = false;
        }
    }
    } // mainItem
}
