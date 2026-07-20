import QtQuick
import QtQuick.Effects
import org.kde.kwin
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore

import "components" as Components

// Declarative KWin script port of the VibeTiles daemon (see ../../../main.cpp /
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
    // when a placement completely covers another window (which resizeOverlapping's
    // edge-slice shrink can't handle), move that window to the largest free grid region
    // instead of leaving it hidden underneath
    property bool relocateCovered: true
    property bool compactAtCursor: false
    // compact mode only: draw a 1:1 outline of the final window rectangle on the real
    // screen while selecting (see the `ghost` Rectangle). On by default - the compact grid
    // is a miniature, so without it a selection gives no sense of the resulting size - but
    // it is extra chrome over the desktop, so it can be turned off.
    property bool ghostPreview: true
    property string hotCorner: "none"
    // when true, any native window drag auto-shows a small top-center single-cell picker
    // after the window has moved past a threshold, no shortcut needed - modeled on
    // KZones/MouseTiler's automatic drag-triggered zone overlays. Opt-in since it changes
    // the feel of every plain window move, not just shortcut-driven placements.
    property bool dragAutoTrigger: false
    // When true, the auto-trigger picker spawns with the cursor at the corner facing the
    // OPPOSITE direction of the drag motion (see dragDirection). Centering would force
    // any selection to include the cursor's spawn cell - making single-cell picks at
    // non-cursor cells impossible, and on a 1x1 picker leaving no room to drag from the
    // middle at all. With directional corner anchoring, the cursor's first inside-picker
    // position is at that trailing corner and dragging diagonally extends a selection
    // away from it - AND the cursor's exit from the picker clears the anchor (see
    // onNativeDragStepped) so a release past the edge doesn't commit a resize the user
    // never confirmed by hovering over a target cell.
    // Independent of compactAtCursor, which only affects non-autoMode compact activations.
    property bool autoAtCursor: false
    // when true, an interactive resize drags every window whose opposite edge is flush
    // against the edge being moved, so a shared border between two tiled windows behaves
    // like one splitter (Windows Snap). Opt-in: it changes the feel of every manual
    // resize, and windows that merely happen to sit flush get pulled along too.
    property bool linkedResize: false
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
        relocateCovered = KWin.readConfig("relocateCovered", true);
        compactAtCursor = KWin.readConfig("compactAtCursor", false);
        ghostPreview = KWin.readConfig("ghostPreview", true);
        hotCorner = hotCornerNames[KWin.readConfig("hotCorner", 0)] || "none";
        dragAutoTrigger = KWin.readConfig("dragAutoTrigger", false);
        autoAtCursor = KWin.readConfig("autoAtCursor", false);
        linkedResize = KWin.readConfig("linkedResize", false);
        monitorOverrides = root.parseMonitorOverrides(KWin.readConfig("monitorsJson", ""));
    }

    // Per-monitor grid overrides, in either of two syntaxes.
    //
    // The plain form is one "OUTPUT = COLSxROWS" per line, which is what the settings
    // dialog now documents - the generic KWin-script config KCM can only do 1:1 scalar
    // binding, so a real per-row table editor isn't available without shipping a compiled
    // KCM, but hand-editing three tokens on a line is a great deal easier than getting
    // nested JSON braces right in a plain text box.
    //
    // The original JSON object form is still accepted, unchanged: it is what any existing
    // install already has stored, and silently dropping those overrides on upgrade would
    // be a data-loss bug. Detected by a leading brace, so the two can't be confused.
    function parseMonitorOverrides(text) {
        const s = String(text || "").trim();
        if (s === "" || s === "{}") return {};

        if (s.charAt(0) === "{") {
            try {
                const parsed = JSON.parse(s);
                // JSON.parse("null")/numbers/strings don't throw but leave a non-object
                // value, which crashes on the next monitorOverrides[name] lookup.
                // JSON.parse("[]") would silently mis-route too - guard for both.
                if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed;
            } catch (e) {
                console.warn("vibetiles: invalid monitorsJson, ignoring overrides:", e);
            }
            return {};
        }

        // name and size are split on the LAST separator, so output names containing '='
        // or ':' (rare, but nothing forbids them) still parse. Blank lines and #-comments
        // are skipped so the field can carry the example as a comment.
        const out = {};
        const lines = s.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (line === "" || line.charAt(0) === "#") continue;
            const cut = Math.max(line.lastIndexOf("="), line.lastIndexOf(":"));
            if (cut < 1) {
                console.warn("vibetiles: skipping unparseable monitor line:", String(line).substring(0, 80));
                continue;
            }
            const name = line.substring(0, cut).trim();
            const size = line.substring(cut + 1).trim().split(/[xX*]/);
            const cols = parseInt(size[0], 10), rows = parseInt(size[1], 10);
            if (name === "" || size.length !== 2 || !(cols > 0) || !(rows > 0)) {
                console.warn("vibetiles: skipping unparseable monitor line:", String(line).substring(0, 80));
                continue;
            }
            out[name] = { gridCols: cols, gridRows: rows };
        }
        return out;
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
    // autoAtCursor positions the picker with the cursor at the corner facing OPPOSITE
    // the drag's motion direction (see dragDirection). If the cursor was moving +X
    // (rightward), the cursor lands at the picker's right edge - canvasX = cursorX -
    // canvasWidth. If -X, the cursor lands at the picker's left edge - canvasX =
    // cursorX. Same for Y, so dragging right-and-down pins the cursor at the
    // picker's bottom-right, dragging left-and-up pins it at the top-left. The picker
    // thus trails the cursor's motion, so continued dragging moves the cursor AWAY from
    // the picker rather than into it.
    property real canvasX: root.autoMode
        ? (autoAtCursor
            ? clamp(
                spawnCursorPos.x - screenGeo.x - (root.dragDirection.x > 0 ? canvasWidth : 0),
                availLocalX,
                availLocalX + availGeo.width - canvasWidth
              )
            : availLocalX + (availGeo.width - canvasWidth) / 2)
        : (isCompact && effectiveCompactAtCursor)
            ? clamp((spawnCursorPos.x - screenGeo.x) - canvasWidth / 2, availLocalX, availLocalX + availGeo.width - canvasWidth)
            : availLocalX + (availGeo.width - canvasWidth) / 2
    property real canvasY: root.autoMode
        ? (autoAtCursor
            ? clamp(
                spawnCursorPos.y - screenGeo.y - (root.dragDirection.y > 0 ? canvasHeight : 0),
                availLocalY,
                availLocalY + availGeo.height - canvasHeight
              )
            : availLocalY + 24)
        : (isCompact && effectiveCompactAtCursor)
            ? clamp((spawnCursorPos.y - screenGeo.y) - canvasHeight / 2, availLocalY, availLocalY + availGeo.height - canvasHeight)
            : availLocalY + (availGeo.height - canvasHeight) / 2
    // guard the divide: during a transient multi-monitor reconfigure canvasWidth can read
    // 0 for a frame, and availGeo.width/0 = Infinity propagates through finishDrag() into a
    // window geometry KWin accepts silently. Fall back to 1:1 until real dimensions arrive.
    property real scaleX: canvasWidth > 0 ? availGeo.width / canvasWidth : 1
    property real scaleY: canvasHeight > 0 ? availGeo.height / canvasHeight : 1

    property bool pickerOpen: false

    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    // re-expresses a Kirigami theme color at a given alpha - used everywhere the overlay
    // needs a translucent tint of a theme color rather than the opaque color itself
    function themeAlpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
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

    // applies screen-specific state for the given screen object: replaces targetScreenObj,
    // screenGeo, availGeo, and activeGridCols/Rows (the last two via the per-output
    // monitorOverrides map). Used by show(), showAuto(), and autoMode's monitor-cross
    // re-home - the same 5-line setup was duplicated in all three before extraction.
    function rehomeForScreen(screen) {
        root.targetScreenObj = screen;
        root.screenGeo = screen.geometry;
        root.availGeo = Workspace.clientArea(KWin.PlacementArea, screen, Workspace.currentDesktop);
        const override = root.monitorOverrides[screen.name];
        root.activeGridCols = (override && override.gridCols > 0) ? override.gridCols : root.gridCols;
        root.activeGridRows = (override && override.gridRows > 0) ? override.gridRows : root.gridRows;
    }

    // forcedTarget: when set (a window object), this activation is drag-triggered - target
    // that window instead of Workspace.activeWindow and seed the selection at the window's
    // current native-drag position instead of starting with no selection.
    function show(forcedTarget) {
        root.loadConfig();

        const isDragTriggered = !!forcedTarget;
        root.dragTriggered = isDragTriggered;
        // a shortcut-driven activation is never the auto-drag picker - clear autoMode
        // explicitly so a stale true (from a picker that didn't route through hide())
        // can't leave isCompact/canvas positioning stuck in auto-mode behaviour.
        root.autoMode = false;
        // compact mode's small, cursor-centered box makes the anchor-point restriction
        // (the selection always has to include wherever the cursor was when the shortcut
        // fired) much more cramped than in fullscreen, where there's enough room to reach
        // most layouts anyway - so drag-triggered activations always use fullscreen,
        // regardless of the configured mode.
        if (isDragTriggered) root.overlayMode = "fullscreen";

        // capture the window to act on before our own popup steals activation - mirrors
        // the daemon's captureActiveWindow(), just synchronous now
        targetWindow = isDragTriggered
            ? forcedTarget
            : (Workspace.activeWindow && Workspace.activeWindow.normalWindow ? Workspace.activeWindow : null);
        targetTitle = targetWindow ? (targetWindow.caption || "") : "";
        targetIconName = targetWindow && targetWindow.resourceClass ? targetWindow.resourceClass.toString() : "";
        spawnCursorPos = Workspace.cursorPos;

        rehomeForScreen(screenAt(spawnCursorPos));

        if (isCompact) refreshWindowList();

        root.shiftHeld = false;
        root.pickerOpen = false;
        root.visible = true;
        // PlasmaQuick::Dialog's prototype is QQuickWindow, so it has requestActivate().
        // These script-owned windows never reliably receive real keyboard focus
        // regardless (confirmed live: Escape/Keys.onEscapePressed never fires even
        // with forceActiveFocus() at the right time) - so skip the Item-level
        // focus attempt that was here before, since it both fails AND now refers
        // to a deleted item. Shift is read off mouse-event modifiers on the canvas
        // MouseArea; Escape has no such workaround, so cancel is right-click.
        root.requestActivate();

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
        root.dragDirection = Qt.point(0, 0);
        // drop the compact-picker window list so a later show() can't briefly display a
        // stale set (a window could have closed while the overlay was hidden); the next
        // compact show() repopulates it via refreshWindowList().
        root.windowList = [];
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
    // sign-of-dx/sign-of-dy of the cursor's motion from autoDragStartPos to the moment
    // the threshold tripped. Captured in onNativeDragStepped right before showAuto, and
    // consumed by canvasX/canvasY to spawn the picker trailing the cursor's motion
    // direction (so continued dragging moves the cursor AWAY from the picker rather than
    // into it - reduces accidental trigger-while-continuing). Stale between activations;
    // reset in hide() for tidiness.
    property point dragDirection: Qt.point(0, 0)

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

        rehomeForScreen(screenAt(spawnCursorPos));

        root.shiftHeld = false;
        root.pickerOpen = false;
        root.dragging = false;
        root.visible = true;
        root.requestActivate();
        root.dragCurrent = root.externalCanvasPoint();
    }

    // ---- linked resize (shared-border co-resize, gated on linkedResize) ----
    //
    // Windows-Snap-style: while one window is being interactively resized, every window
    // whose opposite edge was flush against the moving edge at drag start has that edge
    // follow along, keeping the border between them a single splitter. Nothing here
    // touches the overlay - it's a pure side-effect of the interactiveMoveResize* signals
    // already hooked on every window in hookWindow().
    //
    // Neighbours (and their pre-resize geometry) are captured once at drag start, and each
    // step recomputes each neighbour from that snapshot plus the dragged window's total
    // delta - never incrementally from its current geometry, which would accumulate
    // rounding drift over a long drag and desynchronise the shared edge.
    property var linkedNeighbors: []
    property rect linkedStartGeo: Qt.rect(0, 0, 0, 0)

    // gap-aware: VibeTiles-placed windows sit exactly windowGap apart, so "flush" has to
    // mean "within the gap", plus slack for hand-placed/decorated windows.
    readonly property int linkedTol: Math.max(16, root.windowGap + 12)

    function linkedCandidate(ow, win) {
        // reject a cross-output neighbour only when we positively know both outputs and
        // they differ; if the declarative API doesn't expose output on either window, we
        // can't tell, so fall through to the geometry checks rather than silently dropping
        // every candidate (!= null catches both null and undefined).
        return ow !== win && !ow.minimized && ow.normalWindow && !ow.fullScreen
            && !(win.output != null && ow.output != null && ow.output !== win.output);
    }

    // Which coordinate is `side`'s edge of rect r? Sides are keyed L/R/T/B throughout
    // this section, and double as the keys of the per-edge delta map in stepLinkedResize.
    function linkedEdgeCoord(r, side) {
        if (side === "L") return r.x;
        if (side === "R") return r.x + r.width;
        if (side === "T") return r.y;
        return r.y + r.height;
    }

    // Do a and b run alongside each other on the axis perpendicular to `axis`? Overlapping
    // counts, and so does a gap no wider than tol - two windows stacked with the usual
    // inter-window gap are still consecutive links of the same border.
    function linkedAbuts(a, b, axis, tol) {
        const share = (axis === "x")
            ? Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y)
            : Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
        return share >= -tol;
    }

    // Record that `w`'s `follow` edge (x1 = left, x2 = right, y1 = top, y2 = bottom) tracks
    // the dragged window's `side` edge. One entry per window, with up to four independently
    // tracked edges: a corner drag legitimately moves two of a neighbour's edges at once,
    // and a window collected by two different chains must merge rather than overwrite.
    function linkedAdd(acc, w, geo, follow, side) {
        let e = null;
        for (let i = 0; i < acc.length; i++) {
            if (acc[i].win === w) { e = acc[i]; break; }
        }
        if (!e) {
            e = { win: w, geo: geo, dxStart: "", dxEnd: "", dyStart: "", dyEnd: "" };
            acc.push(e);
        }
        const key = (follow === "x1") ? "dxStart" : (follow === "x2") ? "dxEnd"
                  : (follow === "y1") ? "dyStart" : "dyEnd";
        if (!e[key]) e[key] = side;  // first chain to claim an edge wins
    }

    // Walk the border that the dragged window's `side` edge lies on, collecting every
    // window with an edge on that same line, reachable by a contiguous run of windows
    // alongside it. Contiguity is what makes this safe: matching the line coordinate alone
    // would rope in anything that happened to line up elsewhere on the screen.
    function collectBorderChain(win, side, acc) {
        const g = win.frameGeometry;
        const tol = root.linkedTol;
        const axis = (side === "L" || side === "R") ? "x" : "y";
        const line = root.linkedEdgeCoord(g, side);
        const wins = Workspace.stackingOrder;

        // every candidate with either of its `axis` edges on the line. Which edge it is
        // decides which way that window follows: a window whose LEFT edge is on the line
        // sits to the right of the border and moves its left edge; one whose RIGHT edge is
        // on the line sits to the left and moves its right edge. The gap between adjacent
        // windows is absorbed by tol, so both sides test against the same line value.
        const onLine = [];
        for (let i = 0; i < wins.length; i++) {
            const ow = wins[i];
            if (!root.linkedCandidate(ow, win)) continue;
            const c = ow.frameGeometry;
            const s = (axis === "x") ? c.x : c.y;
            const e = (axis === "x") ? c.x + c.width : c.y + c.height;
            let follow = "";
            if (Math.abs(s - line) <= tol) follow = axis + "1";
            else if (Math.abs(e - line) <= tol) follow = axis + "2";
            else continue;
            onLine.push({
                win: ow, geo: Qt.rect(c.x, c.y, c.width, c.height),
                follow: follow, used: false
            });
        }

        // grow outward from the dragged window until nothing new abuts the run. This is
        // what generalises the earlier "direct neighbour + one hop" rule: in a 2x2 grid,
        // dragging the bottom-right window's left edge reaches the bottom-left window
        // directly, the top-right window by stacking above it, and the top-left window
        // through that - so the whole vertical divider moves as one instead of only its
        // bottom half.
        const chain = [Qt.rect(g.x, g.y, g.width, g.height)];
        let grew = true;
        while (grew) {
            grew = false;
            for (let i = 0; i < onLine.length; i++) {
                const cand = onLine[i];
                if (cand.used) continue;
                for (let j = 0; j < chain.length; j++) {
                    if (!root.linkedAbuts(cand.geo, chain[j], axis, tol)) continue;
                    cand.used = true;
                    chain.push(cand.geo);
                    root.linkedAdd(acc, cand.win, cand.geo, cand.follow, side);
                    grew = true;
                    break;
                }
            }
        }
    }

    function beginLinkedResize(win) {
        const g = win.frameGeometry;
        root.linkedStartGeo = Qt.rect(g.x, g.y, g.width, g.height);
        const acc = [];
        // all four borders unconditionally - which of them actually moves isn't known until
        // the drag is under way (and a corner drag moves two). Sides whose delta stays 0
        // cost nothing per step beyond the no-op check.
        const sides = ["L", "R", "T", "B"];
        for (let i = 0; i < sides.length; i++) root.collectBorderChain(win, sides[i], acc);
        root.linkedNeighbors = acc;
    }

    // A window's declared size constraint on one dimension, or `fallback` if it declares
    // none. Read defensively: whether minSize/maxSize are exposed to declarative scripts
    // isn't something this codebase has confirmed live, and an undefined property read
    // must degrade to the old fixed floor rather than throw once per neighbour per step.
    //
    // Minimums are raised to the fallback, never lowered - the 100px floor stays as a
    // usability guard for apps that declare a uselessly small minimum. Maximums are taken
    // as-is, with KWin's "unconstrained" sentinel treated as unset.
    function linkedLimit(w, kind, dim, fallback) {
        let s;
        try {
            s = (kind === "min") ? w.minSize : w.maxSize;
        } catch (e) {
            return fallback;
        }
        const v = s ? s[dim] : undefined;
        if (typeof v !== "number" || v <= 0) return fallback;
        if (kind === "max" && v >= 100000) return fallback;
        return (kind === "min") ? Math.max(v, fallback) : v;
    }

    function stepLinkedResize(win) {
        if (root.linkedNeighbors.length === 0) return;
        // unlike the neighbour loop below (which catches per-window), this read is called
        // straight from the interactiveMoveResize* signal handlers with no try/catch above
        // it - if the dragged window is being destroyed mid-drag, this would throw out of
        // the handler. Abandon the linked resize instead.
        let g;
        try {
            g = win.frameGeometry;
        } catch (e) {
            root.endLinkedResize();
            return;
        }
        const s = root.linkedStartGeo;
        // per-edge deltas rather than a single "which handle is the user dragging" guess -
        // this falls out correctly for corner drags, where two edges move at once.
        const d = {
            L: g.x - s.x,
            R: (g.x + g.width) - (s.x + s.width),
            T: g.y - s.y,
            B: (g.y + g.height) - (s.y + s.height)
        };
        const MIN = 100;
        for (let i = 0; i < root.linkedNeighbors.length; i++) {
            const n = root.linkedNeighbors[i], c = n.geo;
            const x1 = c.x + (n.dxStart ? d[n.dxStart] : 0);
            const x2 = c.x + c.width + (n.dxEnd ? d[n.dxEnd] : 0);
            const y1 = c.y + (n.dyStart ? d[n.dyStart] : 0);
            const y2 = c.y + c.height + (n.dyEnd ? d[n.dyEnd] : 0);
            if (x1 === c.x && y1 === c.y && x2 === c.x + c.width && y2 === c.y + c.height) continue;
            // clamp rather than clip: a neighbour that can't take the new size simply
            // stops following, leaving the dragged window free to keep shrinking it out
            // of the way instead of the whole drag jamming.
            //
            // Honouring the window's own declared limits (not just a fixed floor) is what
            // keeps it in sync with the border: an app that refuses a geometry smaller
            // than its minimum just keeps its old size, so the border would slide on
            // without it and the layout would silently come apart mid-drag.
            const minW = root.linkedLimit(n.win, "min", "width", MIN);
            const minH = root.linkedLimit(n.win, "min", "height", MIN);
            const maxW = root.linkedLimit(n.win, "max", "width", 0);
            const maxH = root.linkedLimit(n.win, "max", "height", 0);
            if (x2 - x1 < minW || y2 - y1 < minH) continue;
            if ((maxW > 0 && x2 - x1 > maxW) || (maxH > 0 && y2 - y1 > maxH)) continue;
            try {
                n.win.setMaximize(false, false);
                n.win.frameGeometry = Qt.rect(Math.round(x1), Math.round(y1),
                                              Math.round(x2 - x1), Math.round(y2 - y1));
            } catch (e) {
                // neighbour destroyed mid-drag - drop it rather than throwing per step
                root.linkedNeighbors.splice(i, 1);
                i--;
            }
        }
    }

    function endLinkedResize() {
        root.linkedNeighbors = [];
    }

    function onNativeDragStarted(win) {
        root.nativeDragWindow = win;
        root.nativeDragActive = true;
        // win.resize distinguishes an edge/corner drag from a plain move; both fire this
        // same signal. Fullscreen windows have no meaningful neighbours to link.
        if (root.linkedResize && win.normalWindow && win.resize && !win.fullScreen) {
            root.beginLinkedResize(win);
        } else {
            root.endLinkedResize();
        }
        // win.move is true only for genuine interactive moves; resizes fire the same
        // interactiveMoveResizeStarted signal but set win.resize instead, and the
        // picker should never pop up over a corner/edge drag. (The drag-triggered
        // activation path above is intentionally left unguarded - if the user holds
        // the shortcut mid-resize, that's their explicit choice to retarget.)
        if (root.dragAutoTrigger && !root.visible && win.normalWindow && win.move) {
            root.autoDragPending = true;
            root.autoDragStartPos = Workspace.cursorPos;
        }
    }

    function onNativeDragStepped(win) {
        if (win !== root.nativeDragWindow) return;
        root.stepLinkedResize(win);
        // shiftHeld is otherwise updated off mouse-modifier flags on the canvas
        // MouseArea, but the overlay's MouseArea gets no events during a native
        // drag (the compositor keeps the grab). KWin's QML host doesn't expose
        // Qt.application.queryKeyboardModifiers(), so we have to live without
        // shift-doubling during native drag activations - same as before this
        // script existed; restore parity rather than ship a broken call.
        if (root.visible && root.dragTriggered && root.targetWindow === win) {
            // follow the cursor across monitors, same as the autoMode branch below: the
            // overlay was homed to whichever screen the shortcut fired on, and a drag
            // routinely leaves it. Unlike autoMode there's no anchor to drop - the
            // selection's start point is re-seeded at the cursor on the new screen, since
            // the old one was in the previous screen's local coordinates and doesn't
            // translate. The effect is that crossing a monitor restarts the selection
            // there rather than stretching a meaningless rectangle between screens.
            const curScreen = root.screenAt(Workspace.cursorPos);
            if (curScreen !== root.targetScreenObj) {
                root.rehomeForScreen(curScreen);
                const np = root.externalCanvasPoint();
                root.dragStart = np;
                root.dragCurrent = np;
                root.dragging = true;
            } else {
                root.dragCurrent = root.externalCanvasPoint();
            }
            return;
        }
        if (root.autoDragPending && !root.visible) {
            const p = Workspace.cursorPos;
            const dx = p.x - root.autoDragStartPos.x, dy = p.y - root.autoDragStartPos.y;
            // compare squared distances - avoids a sqrt per drag step (cheap in isolation,
            // but high-Hz pointers fire this on every motion tick).
            if (dx * dx + dy * dy >= root.autoDragThreshold * root.autoDragThreshold) {
                root.autoDragPending = false;
                // capture direction-of-motion before showAuto so the picker can spawn
                // trailing the cursor's drag direction (see canvasX/canvasY).
                root.dragDirection = Qt.point(Math.sign(dx), Math.sign(dy));
                root.showAuto(win);
            }
            return;
        }
        if (root.visible && root.autoMode && root.targetWindow === win) {
            // the picker is pinned to whichever screen the drag started on, but a drag
            // routinely crosses monitors - re-home it (geometry, work area, per-monitor
            // grid override) to follow the cursor's current screen. Any in-progress
            // anchor/selection is screen-local, so it gets dropped and has to be
            // re-picked on the new screen rather than translated.
            const curScreen = root.screenAt(Workspace.cursorPos);
            if (curScreen !== root.targetScreenObj) {
                root.rehomeForScreen(curScreen);
                root.autoAnchored = false;
                root.dragging = false;
            }

            const p = root.externalCanvasPoint();
            root.dragCurrent = p;
            if (root.autoAnchored && !root.pointInCanvas(p)) {
                // cursor left the picker - drop the anchor and any in-progress
                // selection. onNativeDragFinished then sees autoAnchored=false and
                // calls hide() instead of finishDrag(), so a release past the
                // picker's edge doesn't commit a resize the user never confirmed by
                // hovering over a target cell. On re-entry, the next branch
                // re-anchors at the new cursor position.
                root.autoAnchored = false;
                root.dragging = false;
            } else if (!root.autoAnchored && root.pointInCanvas(p)) {
                root.dragStart = p;
                root.autoAnchored = true;
                root.dragging = true;
            }
        }
    }

    function onNativeDragFinished(win) {
        if (win !== root.nativeDragWindow) return;
        root.stepLinkedResize(win);
        root.endLinkedResize();
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
            root.endLinkedResize();
            // only the drag we're actually tracking cancels a pending auto-trigger; a
            // bystander window closing mid-drag must not clear it (that would swallow a
            // legitimate pending trigger for the window still being dragged).
            root.autoDragPending = false;
        }
        // forget the window's handlers - its connections die with it, but the entry would
        // otherwise sit in hookedWindows for the rest of the session. Only the bookkeeping
        // is dropped here, not the connections: disconnecting win.closed from inside its
        // own emission is exactly the case worth not being clever about.
        for (let i = 0; i < root.hookedWindows.length; i++) {
            if (root.hookedWindows[i].win === win) {
                root.hookedWindows.splice(i, 1);
                break;
            }
        }
    }

    // Every window we've connected to, with the exact handler functions used - a closure
    // can only be disconnected through the same reference that was connected, so these
    // have to be retained rather than created inline at connect time.
    //
    // Without this, unloading the script (which bump.sh does on every deploy) tears down
    // the root object but leaves these connections live on each window, and they then
    // throw "Cannot read property 'onNativeDragStepped' of null" on every step of every
    // subsequent drag - once per dead generation, accumulating for the life of the
    // kwin_wayland process.
    property var hookedWindows: []

    function hookWindow(win) {
        // interactiveMove* signals only fire for normal windows anyway, but skip
        // panels/popups/transients upfront - 4 signal connections per dot on the
        // desktop adds up, and Workspace.windowAdded fires for everything.
        if (!win.normalWindow) return;
        const h = {
            win: win,
            started: () => root.onNativeDragStarted(win),
            stepped: () => root.onNativeDragStepped(win),
            finished: () => root.onNativeDragFinished(win),
            closed: () => root.onNativeDragWindowClosed(win)
        };
        root.hookedWindows.push(h);
        win.interactiveMoveResizeStarted.connect(h.started);
        win.interactiveMoveResizeStepped.connect(h.stepped);
        win.interactiveMoveResizeFinished.connect(h.finished);
        win.closed.connect(h.closed);
    }

    function unhookWindow(win) {
        for (let i = 0; i < root.hookedWindows.length; i++) {
            const h = root.hookedWindows[i];
            if (h.win !== win) continue;
            root.hookedWindows.splice(i, 1);
            try {
                win.interactiveMoveResizeStarted.disconnect(h.started);
                win.interactiveMoveResizeStepped.disconnect(h.stepped);
                win.interactiveMoveResizeFinished.disconnect(h.finished);
                win.closed.disconnect(h.closed);
            } catch (e) {
                // window already torn down - the connections went with it
            }
            return;
        }
    }

    // Drop every connection before the root object goes away. Without this the handlers
    // outlive the script and fire against a null root forever after (see hookedWindows).
    Component.onDestruction: {
        const hooks = root.hookedWindows.slice();
        for (let i = 0; i < hooks.length; i++) root.unhookWindow(hooks[i].win);
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
        // the picker list is debounced (refreshTimer), so entry.win can have closed in the
        // gap between the last refresh and this click. Selecting a dead window sets a dead
        // target and commit() then silently no-ops - drop the stale entry instead. The
        // normalWindow read is itself wrapped: touching a torn-down window throws.
        try {
            if (!entry || !entry.win || !entry.win.normalWindow) return;
        } catch (e) {
            return;
        }
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
        // `target` is already the placed window's final geometry, inset by windowGap/2 - so
        // retreating a neighbour to exactly the overlap edge leaves the two frames touching,
        // with no gap at all. Back it off by the full gap instead, which reproduces the
        // spacing two grid-placed windows get by construction (each inset windowGap/2 from
        // the shared cell boundary).
        const gap = root.windowGap;
        const others = Workspace.stackingOrder;
        for (let j = 0; j < others.length; j++) {
            const ow = others[j];
            // per-window guard: a sibling destroyed mid-loop shouldn't abort adjusting the
            // rest. The call site already has an outer try/catch, but that catches once for
            // the whole loop - this keeps a single dead window from cutting the pass short.
            try {
                if (ow === root.targetWindow || ow.minimized || !ow.normalWindow) continue;
                const c = ow.frameGeometry;
                const ov = overlapRect(c, target);
                if (!ov) continue;
                let nr = null;
                if (ov.width >= c.width - EPS) {
                    if (Math.abs(ov.y - c.y) <= EPS) {
                        const top = ov.y + ov.height + gap;
                        nr = Qt.rect(c.x, top, c.width, (c.y + c.height) - top);
                    } else if (Math.abs((ov.y + ov.height) - (c.y + c.height)) <= EPS) {
                        nr = Qt.rect(c.x, c.y, c.width, (ov.y - gap) - c.y);
                    }
                }
                if (!nr && ov.height >= c.height - EPS) {
                    if (Math.abs(ov.x - c.x) <= EPS) {
                        const left = ov.x + ov.width + gap;
                        nr = Qt.rect(left, c.y, (c.x + c.width) - left, c.height);
                    } else if (Math.abs((ov.x + ov.width) - (c.x + c.width)) <= EPS) {
                        nr = Qt.rect(c.x, c.y, (ov.x - gap) - c.x, c.height);
                    }
                }
                if (nr && nr.width > 50 && nr.height > 50) {
                    ow.setMaximize(false, false);
                    ow.frameGeometry = nr;
                }
            } catch (e) {
                continue;
            }
        }
    }

    // ---- relocate fully-covered windows (gated on relocateCovered) ----
    //
    // resizeOverlappingWindows only handles a clean edge slice - a window the placement
    // covers *entirely* falls through it (the shrink computes a zero-size remainder, which
    // fails its own > 50 guard), leaving the window intact but completely hidden
    // underneath. This moves it to the largest free region instead.
    //
    // "Free region" is defined over the grid rather than as a true maximal-empty-rectangle
    // search: candidates are all grid-aligned rectangles, tested at their final inset
    // geometry against every other window. That keeps the result predictable and aligned
    // with everything else the tiler does, and the candidate count is small enough
    // (~200 for a 6x4 grid) to brute-force once per commit.

    // Largest grid-aligned rectangle on the current screen that no other window occupies,
    // as a final (gap-inset) geometry, or null if nothing big enough is free.
    // every window that counts as occupying space on the current screen, `exceptWin` aside
    // Is this something the user thinks of as a window - i.e. something that both counts as
    // occupying space and is worth relocating? `normalWindow` alone is not enough: confirmed
    // live, plasmashell's desktop/wallpaper window passes it and reports the full screen
    // rect (0,681 3440x1440), which made every candidate region look 100% occupied and
    // silently disabled free-region search entirely. Helper windows kept out of the taskbar
    // (xwaylandvideobridge) are excluded for the same reason. Read defensively - an
    // undefined property must not end up skipping everything.
    function isRealWindow(w) {
        if (!w || w.minimized || !w.normalWindow) return false;
        if (w.skipTaskbar === true || w.skipSwitcher === true) return false;
        if (w.desktopWindow === true || w.dock === true) return false;
        // our own overlay is in the stacking order too, and in the drag-triggered path it is
        // forced fullscreen - so without this it reports the whole screen as occupied at
        // exactly the moment commit() asks where the free space is, pinning every candidate
        // region at 100% occupied and silently disabling free-region search altogether
        // (confirmed live: class and caption both empty, every type flag false, geometry
        // exactly the output rect). Script-owned windows carry no resourceClass; every real
        // application window does.
        if (!w.resourceClass || String(w.resourceClass) === "") return false;
        return true;
    }

    function occupiedRects(exceptWin) {
        const occupied = [];
        const wins = Workspace.stackingOrder;
        for (let i = 0; i < wins.length; i++) {
            const ow = wins[i];
            // isRealWindow() and the frameGeometry read below both touch a live window
            // object that can vanish during the scan - a dead one simply doesn't count as
            // occupying space, so skip it rather than throw the whole occupancy build.
            try {
                if (ow === exceptWin || !root.isRealWindow(ow)) continue;
                const c = ow.frameGeometry;
                if (!root.overlapRect(c, root.availGeo)) continue;
                occupied.push(c);
            } catch (e) {
                continue;
            }
        }
        return occupied;
    }

    // The grid-aligned rectangle nearest to an arbitrary one, as a final (gap-inset)
    // geometry. Rounds to the closest cell boundary rather than enclosing outward: this
    // tidies a floating window's geometry into the grid, and growing it to enclose would
    // just make it more likely to collide with whatever is next to it.
    function snapRectToGrid(r) {
        const cols = root.activeGridCols, rows = root.activeGridRows;
        const cellW = root.availGeo.width / cols, cellH = root.availGeo.height / rows;
        const inset = root.windowGap / 2;
        let c1 = Math.round((r.x - root.availGeo.x) / cellW);
        let c2 = Math.round((r.x + r.width - root.availGeo.x) / cellW);
        let r1 = Math.round((r.y - root.availGeo.y) / cellH);
        let r2 = Math.round((r.y + r.height - root.availGeo.y) / cellH);
        c1 = root.clamp(c1, 0, cols - 1);
        r1 = root.clamp(r1, 0, rows - 1);
        c2 = root.clamp(c2, c1 + 1, cols);
        r2 = root.clamp(r2, r1 + 1, rows);
        return Qt.rect(
            root.availGeo.x + c1 * cellW + inset,
            root.availGeo.y + r1 * cellH + inset,
            (c2 - c1) * cellW - root.windowGap,
            (r2 - r1) * cellH - root.windowGap
        );
    }

    // Which grid cells are already spoken for. Occupancy is decided per cell rather than by
    // summing overlap areas across a candidate: summing double-counts windows that overlap
    // each other, so a region could measure as 138% occupied (seen live) and no percentage
    // threshold over that number means anything. A cell counts as taken when a *single*
    // window covers at least CELL_FILL of it, which needs no union-area math and matches how
    // the rest of the tiler reasons about space.
    // Returns a cols*rows array of booleans, indexed c * rows + r.
    function buildCellOccupancy(exceptWin) {
        const cols = root.activeGridCols, rows = root.activeGridRows;
        if (cols <= 0 || rows <= 0) return [];
        const cellW = root.availGeo.width / cols, cellH = root.availGeo.height / rows;
        const CELL_FILL = 0.35;
        const occ = root.occupiedRects(exceptWin);
        const taken = new Array(cols * rows);
        for (let c = 0; c < cols; c++) {
            for (let r = 0; r < rows; r++) {
                const cell = Qt.rect(root.availGeo.x + c * cellW, root.availGeo.y + r * cellH,
                                     cellW, cellH);
                const limit = cellW * cellH * CELL_FILL;
                let hit = false;
                for (let k = 0; k < occ.length && !hit; k++) {
                    const o = root.overlapRect(cell, occ[k]);
                    if (o && o.width * o.height >= limit) hit = true;
                }
                taken[c * rows + r] = hit;
            }
        }
        return taken;
    }

    // Best grid-aligned region to move a covered window into, as a final (gap-inset)
    // geometry, or null if nothing is good enough.
    //
    // Are all the cells an arbitrary rectangle covers free? Membership is by cell centre, so
    // the gap inset on an already-snapped rect doesn't matter.
    function regionFree(r, taken) {
        const cols = root.activeGridCols, rows = root.activeGridRows;
        if (cols <= 0 || rows <= 0) return false;
        const cellW = root.availGeo.width / cols, cellH = root.availGeo.height / rows;
        for (let c = 0; c < cols; c++) {
            for (let rr = 0; rr < rows; rr++) {
                const cx = root.availGeo.x + (c + 0.5) * cellW;
                const cy = root.availGeo.y + (rr + 0.5) * cellH;
                if (cx < r.x || cx > r.x + r.width || cy < r.y || cy > r.y + r.height) continue;
                if (taken[c * rows + rr]) return false;
            }
        }
        return true;
    }

    // A candidate qualifies only when every cell it spans is free. That is workable now that
    // occupancy is per-cell: an earlier version tested the candidate rectangle against raw
    // window rects and required it to be entirely untouched, which found nothing on a real
    // desktop because a floating window straddling a boundary clips every candidate near it.
    // The placement itself counts as an occupier, so the window can never be sent back
    // underneath it - the one outcome that would defeat the point.
    function findFreeRegion(forWin, placed) {
        const cols = root.activeGridCols, rows = root.activeGridRows;
        if (cols <= 0 || rows <= 0) return null;
        const cellW = root.availGeo.width / cols, cellH = root.availGeo.height / rows;
        const inset = root.windowGap / 2;

        // a relocated window still has to be usable - don't shove it into a sliver
        const minW = Math.max(200, root.linkedLimit(forWin, "min", "width", 0));
        const minH = Math.max(150, root.linkedLimit(forWin, "min", "height", 0));

        const taken = root.buildCellOccupancy(forWin);

        let best = null, bestScore = 0;
        for (let c1 = 0; c1 < cols; c1++) {
            for (let c2 = c1 + 1; c2 <= cols; c2++) {
                for (let r1 = 0; r1 < rows; r1++) {
                    for (let r2 = r1 + 1; r2 <= rows; r2++) {
                        let free = true;
                        for (let c = c1; c < c2 && free; c++) {
                            for (let r = r1; r < r2 && free; r++) {
                                if (taken[c * rows + r]) free = false;
                            }
                        }
                        if (!free) continue;
                        const cand = Qt.rect(
                            root.availGeo.x + c1 * cellW + inset,
                            root.availGeo.y + r1 * cellH + inset,
                            (c2 - c1) * cellW - root.windowGap,
                            (r2 - r1) * cellH - root.windowGap
                        );
                        if (cand.width < minW || cand.height < minH) continue;
                        if (placed && root.overlapRect(cand, placed)) continue;
                        const score = cand.width * cand.height;  // biggest free region wins
                        if (score <= bestScore) continue;
                        best = cand;
                        bestScore = score;
                    }
                }
            }
        }
        return best;
    }

    function relocateCoveredWindows(target, vacated) {
        const EPS = 24;
        const others = Workspace.stackingOrder;
        const covered = [];
        for (let j = 0; j < others.length; j++) {
            const ow = others[j];
            if (ow === root.targetWindow || !root.isRealWindow(ow)) continue;
            const c = ow.frameGeometry;
            const ov = root.overlapRect(c, target);
            if (!ov) continue;
            // fully covered on both axes - a window covered on only one is an edge slice,
            // which resizeOverlappingWindows already shrinks properly
            if (ov.width >= c.width - EPS && ov.height >= c.height - EPS) covered.push(ow);
        }

        // The spot the placed window just left is the one region guaranteed to be free,
        // and on a tiled screen it's usually the ONLY one - free-region search comes up
        // empty precisely when this feature is most wanted (confirmed live: every covered
        // window logged "spot NONE" on a tiled screen). Claimed by the first covered
        // window that can use it; a second one has to fall back to the region search.
        let swapAvailable = vacated && vacated.width >= 200 && vacated.height >= 150
            && !root.overlapRect(vacated, target);
        for (let j = 0; j < covered.length; j++) {
            // recomputed per window, so two windows covered by one placement can't both be
            // sent to the same spot - the first one placed counts as occupied for the next
            let spot = root.findFreeRegion(covered[j], target);
            if (!spot && swapAvailable) {
                // The vacated slot is whatever geometry the placed window happened to have,
                // which for a floating window is an arbitrary rectangle - dropping the
                // covered window straight into it just moves the untidiness around. Snap it
                // to the grid so the result looks placed rather than inherited, and keep the
                // raw rect only if the snapped version would collide with something (the
                // grid region around a floating window is not necessarily free).
                const snapped = root.snapRectToGrid(vacated);
                const usable = !root.overlapRect(snapped, target)
                    && root.regionFree(snapped, root.buildCellOccupancy(covered[j]));
                spot = usable ? snapped : vacated;
                swapAvailable = false;  // one window per vacated slot
            }
            // nothing free and nothing vacated: leave the window where it is rather than
            // invent a position. It stays hidden underneath, which is the old behaviour,
            // but a guessed spot on a full screen would be worse than a predictable no-op.
            if (!spot) continue;
            try {
                covered[j].setMaximize(false, false);
                covered[j].frameGeometry = Qt.rect(Math.round(spot.x), Math.round(spot.y),
                                                   Math.round(spot.width), Math.round(spot.height));
            } catch (e) {
                console.warn("vibetiles: covered-window relocate failed:", e);
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
        // snapshot before the write - this is the slot the placement frees up, and it's
        // what a covered window falls back to when no free region exists (see
        // relocateCoveredWindows). Only meaningful if the window was on this screen to
        // begin with; a target dragged in from another monitor vacates nothing here.
        const pg = targetWindow.frameGeometry;
        const vacated = root.overlapRect(pg, root.availGeo)
            ? Qt.rect(pg.x, pg.y, pg.width, pg.height) : null;
        targetWindow.setMaximize(false, false);
        try {
            targetWindow.frameGeometry = rect;
        } catch (e) {
            // can throw if the window is being destroyed between the read and the write
            console.warn("vibetiles: target window vanished during commit:", e);
            hide();
            return;
        }
        // relocate before shrink, so the covered-window test sees pre-shrink geometry. The
        // two cases are disjoint (a fully covered window has no edge slice to shrink), but
        // ordering it this way keeps that independence from being load-bearing.
        if (relocateCovered) {
            try {
                relocateCoveredWindows(rect, vacated);
            } catch (e) {
                console.warn("vibetiles: covered-window relocate threw:", e);
            }
        }
        if (resizeOverlapping) {
            try {
                resizeOverlappingWindows(rect);
            } catch (e) {
                // a sibling window we tried to make-room for was likely destroyed mid-loop
                console.warn("vibetiles: overlap-resize threw:", e);
            }
        }
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

        // Complementary is the color set Plasma itself uses for OSD-style overlays that
        // sit on top of arbitrary desktop content (e.g. the volume/brightness OSD) -
        // dark and high-contrast by design, and it tracks the active Plasma color scheme
        // (Breeze Dark/Light, custom schemes, etc) automatically. inherit: false so it
        // doesn't pick up whatever color set the KWin script host's implicit parent uses.
        Kirigami.Theme.colorSet: Kirigami.Theme.Complementary
        Kirigami.Theme.inherit: false

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
        function onWindowAdded(win) { root.hookWindow(win); refreshTimer.restart(); }
        function onWindowRemoved() { refreshTimer.restart(); }
    }

    // debounced refresh of the compact-mode window picker so newly opened/closed
    // windows show up while the overlay is up. 200ms collapses a burst of adds/removes
    // (workspace switch, app launch) into a single refreshWindowList() call.
    Timer {
        id: refreshTimer
        interval: 200
        repeat: false
        onTriggered: if (root.visible && root.isCompact) root.refreshWindowList()
    }

    // background: click here (outside the canvas, only relevant in compact mode) cancels
    MouseArea {
        anchors.fill: parent
        onClicked: root.hide()
    }

    // Compact mode only: a 1:1 ghost of the final window rectangle, drawn on the real
    // screen behind the little grid box. The compact grid is a miniature of the whole
    // output, so a selection there gives no sense of the actual size the window will end
    // up - this is the "you are here" for that. Deliberately drawn from snappedRect()
    // rather than rawRect(): unlike the in-canvas preview (which tracks the raw cursor so
    // small drags still register visually), this one's whole job is to show the committed
    // outcome, so it must land exactly where commit() will put the window - same
    // canvas->screen mapping as finishDrag(), same windowGap inset as commit().
    // Fullscreen mode skips it: the canvas already covers the screen 1:1 there, so the
    // ghost would sit exactly on top of the existing selection rectangle.
    Rectangle {
        id: ghost
        property rect g: root.snappedRect()
        visible: root.ghostPreview && root.isCompact && root.dragging
            && g.width > 0 && g.height > 0
        x: root.availLocalX + g.x * root.scaleX + root.windowGap / 2
        y: root.availLocalY + g.y * root.scaleY + root.windowGap / 2
        width: Math.max(0, g.width * root.scaleX - root.windowGap)
        height: Math.max(0, g.height * root.scaleY - root.windowGap)
        color: root.themeAlpha(Kirigami.Theme.highlightColor, 0.18)
        border.color: root.themeAlpha(Kirigami.Theme.highlightColor, 0.9)
        border.width: 2
        radius: 4
    }

    Rectangle {
        id: canvas
        x: root.canvasX
        y: root.canvasY
        width: root.canvasWidth
        height: root.canvasHeight
        color: root.themeAlpha(Kirigami.Theme.backgroundColor, root.isCompact ? 0.8 : 0.13)
        border.color: root.isCompact ? root.themeAlpha(Kirigami.Theme.textColor, 0.33) : "transparent"
        border.width: root.isCompact ? 1 : 0
        radius: root.isCompact ? 6 : 0

        // fullscreen mode fills the entire dialog/screen, so a shadow would have no
        // visible edge to fall against - only worth the layer cost in compact mode,
        // where canvas is a small floating box.
        layer.enabled: root.isCompact
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.6)
            shadowBlur: 0.6
            shadowVerticalOffset: 3
        }

        Repeater {
            model: root.effCols - 1
            Rectangle {
                x: (index + 1) * (canvas.width / root.effCols)
                y: 0
                width: 1
                height: canvas.height
                color: root.themeAlpha(Kirigami.Theme.textColor, 0.2)
            }
        }
        Repeater {
            model: root.effRows - 1
            Rectangle {
                x: 0
                y: (index + 1) * (canvas.height / root.effRows)
                width: canvas.width
                height: 1
                color: root.themeAlpha(Kirigami.Theme.textColor, 0.2)
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
                color: root.themeAlpha(Kirigami.Theme.highlightColor, 0.27)
            }
        }

        Rectangle {
            visible: root.dragging
            color: root.themeAlpha(Kirigami.Theme.highlightColor, 0.33)
            border.color: Kirigami.Theme.highlightedTextColor
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
        color: root.themeAlpha(Kirigami.Theme.backgroundColor, 0.87)
        radius: 6
        border.color: root.themeAlpha(Kirigami.Theme.textColor, 0.33)
        border.width: 1

        layer.enabled: visible
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.6)
            shadowBlur: 0.5
            shadowVerticalOffset: 2
        }

        Row {
            id: titleRow
            anchors.centerIn: parent
            spacing: 8
            Kirigami.Icon {
                source: root.targetIconName || "preferences-system-windows"
                width: 18
                height: 18
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.targetTitle
                color: Kirigami.Theme.textColor
                font.pixelSize: 13
                elide: Text.ElideRight
                width: Math.min(implicitWidth, 240)
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.pickerOpen ? "▴" : "▾"
                color: Kirigami.Theme.disabledTextColor
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
        color: root.themeAlpha(Kirigami.Theme.backgroundColor, 0.87)
        radius: 6
        border.color: root.themeAlpha(Kirigami.Theme.textColor, 0.33)
        border.width: 1
        clip: true

        layer.enabled: visible
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.6)
            shadowBlur: 0.5
            shadowVerticalOffset: 2
        }

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
                            color: root.themeAlpha(Kirigami.Theme.textColor, 0.2)
                        }
                        Text {
                            visible: parent.isNewGroup
                            text: modelData.screen === (root.targetScreenObj ? root.targetScreenObj.name : "") ? "This Display" : modelData.screen
                            color: Kirigami.Theme.disabledTextColor
                            font.pixelSize: 10
                            font.bold: true
                            topPadding: index === 0 ? 0 : 4
                            bottomPadding: 2
                        }

                        Rectangle {
                            width: parent.width
                            height: 28
                            radius: 4
                            color: entryMouse.containsMouse ? root.themeAlpha(Kirigami.Theme.highlightColor, 0.2) : "transparent"

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 6
                                spacing: 8
                                Kirigami.Icon {
                                    source: modelData.icon || "preferences-system-windows"
                                    width: 16
                                    height: 16
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: modelData.title
                                    color: Kirigami.Theme.textColor
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

    // No Item-level Keys handlers here: confirmed live, script-owned windows don't
    // reliably receive real keyboard focus even with forceActiveFocus(), so Keys.*
    // doesn't fire. Cancel is right-click on the canvas MouseArea; Shift is read off
    // mouse-event modifiers (and off Qt.application.queryKeyboardModifiers() in the
    // native-drag paths where the canvas MouseArea gets no events at all - see
    // onNativeDragStepped).
    } // mainItem
}
