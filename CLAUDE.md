# DivvyGrid

A Divvy-style click-drag window tiler for KDE Plasma 6 / KWin on Wayland. Hold a
global shortcut (default Meta+Alt+D), a fullscreen (or compact) grid overlay
appears, drag a rectangle across grid cells, release, and the previously-active
window snaps to that region.

Ships as a **declarative KWin script** (`kwinscript/`) — no compiler, no Qt6/KF6
dev headers, just symlink one directory into `~/.local/share/kwin/scripts/` and
enable it. This replaced an earlier standalone Qt6/KF6 daemon (`main.cpp` +
root-level `main.qml` + `settings/`), which is still present in the repo as a
fallback reference but is no longer the primary implementation and will be
deleted once the script has proven itself in daily use for a while — don't
build or deploy it unless specifically asked to.

## Architecture

Everything runs inside `kwin_wayland` itself via Plasma 6's declarative KWin
script API (`X-Plasma-API: declarativescript`), which exposes a full
`QQmlEngine` with privileged access to `Workspace.*` — no D-Bus, no injected
one-shot scripts, no separate daemon process.

- **`kwinscript/metadata.json`** — KPackage metadata. `KPlugin.Id` /
  `X-KDE-PluginKeyword` (currently `"divvygrid14"`, see "Plugin ID" below) is
  both the kwinrc config-group key (`[Script-<id>]`) and the cache key for
  KWin's in-process compiled-QML cache.
- **`kwinscript/contents/ui/main.qml`** — the entire overlay: grid, drag/snap,
  compact mode, title bar, multi-monitor window picker, shift-to-double grid
  resolution, overlap-resize on commit, hot-corner `ScreenEdgeHandler`s,
  drag-triggered activation, and the auto-trigger-on-drag picker (see below
  for the last two). Root is a `PlasmaCore.Dialog` (not a
  plain `QtQuick Window` — a bare `Window` with popup flags gets silently
  swallowed by the declarative-script host's own dialog presentation instead
  of appearing; this was confirmed live). `Workspace.activeWindow`,
  `Workspace.cursorPos`, `Workspace.screens`, `Workspace.stackingOrder`,
  `Workspace.clientArea(...)`, and per-window `frameGeometry` are read/written
  directly and synchronously.
- **`kwinscript/contents/ui/components/Shortcuts.qml`** — a `ShortcutHandler`
  registering the global shortcut and emitting `showOverlay()`. Replaces
  `KGlobalAccel` + `QAction`; the shortcut stays user-rebindable from System
  Settings → Shortcuts, same as before.
- **`kwinscript/contents/config/main.xml`** — kcfg schema for every config
  entry, auto-bound into `~/.config/kwinrc` under `[Script-divvygrid14]`.
- **`kwinscript/contents/ui/config.ui`** — the Qt Widgets settings form (Qt
  Designer XML), auto-bound to kcfg entries via `kcfg_<entryName>` widget
  names, rendered by KWin's built-in "Configure..." dialog for scripts
  (`kcm_kwin4_genericscripted`) — no custom compiled KCM needed. Read live by
  the KCM every time it opens, so changes here take effect immediately with
  no reload/cache-bump step (unlike `main.qml` — see below).

No `~/.config/divvygrid/config.json`, no separate settings binary, no
`LayerShellQt`, no autostart `.desktop` files — System Settings' own "KWin
Scripts" page is the enable/disable/configure surface, and the script is
loaded and driven entirely by `kwin_wayland`.

## Deploy / reload

Two scripts in the repo root do the work; the manual procedures below are
kept here only as reference for how they behave:

- **`./install.sh`** — first-time setup. Reads the current plugin ID from
  `metadata.json`, symlinks `kwinscript/` into
  `~/.local/share/kwin/scripts/<id>`, enables it, and reconfigures KWin.
  Idempotent.
- **`./bump.sh`** — every edit to `kwinscript/contents/ui/main.qml` (or
  anything `main.qml` imports) requires this, because KWin caches compiled
  QML per plugin ID. The script rewrites `metadata.json` to the next free
  `divvygrid<N>` name, creates a fresh symlink, migrates every key under
  the old `[Script-<oldId>]` kwinrc section forward, disables + unloads
  the old ID, and verifies the new one loads.

- **`config.ui` / `main.xml` changes**: take effect immediately — just
  reopen System Settings' "Configure..." dialog for the script, no reload
  needed.
- **`main.qml` changes**: KWin caches compiled QML per plugin ID for the
  life of `kwin_wayland`, so editing `main.qml` in place and reconfiguring
  is **not** enough — run `./bump.sh`.
- Binary for D-Bus CLI calls is `qdbus-qt6` (also available as `qdbus`) —
  `qdbus6` does not exist on this system.

### Why `bump.sh` exists: plugin-ID cache-busting

To force a fresh QML recompile after editing `main.qml`, the script package
itself has to look like a new plugin to KWin — `KPlugin.Id` /
`X-KDE-PluginKeyword` are both the `[Script-<id>]` group name in kwinrc
*and* the cache key for KWin's compiled-QML cache. `bump.sh` handles all
of the following, which is what the old manual procedure was doing:

- bumping the ID in `metadata.json` and creating a fresh symlink under
  the new ID,
- copying every per-script config key forward to `[Script-<newId>]`
  (otherwise every previously-set value is silently lost under the old
  section name — `bump.sh` parses kwinrc directly to find them, rather
  than relying on memory of which keys were set; that's caused lost
  values in past bumps),
- flipping the enabled flag (new on, old off),
- `unloadScript(oldId)` + `reconfigure` over D-Bus. Leaving the old ID
  enabled lets both scripts register a `ShortcutHandler` under the
  identical name in the same `kglobalaccel` "kwin" component, which is
  a real shortcut-ownership race (not just a duplicate System Settings
  row). Whichever script holds the grab responds to Meta+Alt+D,
  nondeterministically.

Current plugin ID is `divvygrid14` (the integer suffix has bumped many
times during development — every `main.qml` edit costs one. Check
`KPlugin.Id` in `metadata.json` for the current live value rather than
trusting this doc, since it will drift the next time `main.qml` changes).
Consolidating back to the canonical `"divvygrid"` string is still pending
— do it only with fresh explicit approval, since guaranteeing a clean
cache reset for that reused ID likely needs a full
`plasma-kwin_wayland.service` restart, which kills every running Wayland
app.

## Gotchas / lessons learned

- **A plain `QComboBox`'s auto-bindable property is `currentIndex` (int), not
  `currentText`.** Binding a `String`-typed kcfg entry to a combo box (e.g.
  `mode`, `hotCorner`) silently stores the numeric index as text instead of
  the selected item's name, so string comparisons against it in `main.qml`
  never match. Fix: type such entries `Int` in `main.xml`, and map
  index→name manually in QML (`modeNames`/`hotCornerNames` arrays in
  `main.qml`), matching `config.ui`'s item order exactly.
- **`QPlainTextEdit`'s auto-bindable property is `plainText` (`QString`)**,
  so it binds directly to a `String` kcfg entry for free-form/JSON fields —
  used for `monitorsJson` (per-monitor grid overrides), following the same
  pattern the `kzones` KWin script uses for its own JSON config
  (`layoutsJson`).
- **The generic KWin-script config dialog only does simple 1:1 scalar
  binding** (spinbox↔int, checkbox↔bool, combobox↔int/string) — it can't
  run custom per-row/dynamic UI (e.g. an add/remove-row per-monitor table
  with screen-name dropdowns, like the old compiled daemon's settings GUI
  had). A raw-JSON `QPlainTextEdit` is the pragmatic zero-build-dependency
  tradeoff; a nicer table editor would require shipping a real compiled KCM
  plugin, which reintroduces the Qt6/KF6-dev-headers dependency this
  rewrite exists to eliminate.
- **These script-owned windows never reliably receive real keyboard focus**,
  even after `requestActivate()` + `forceActiveFocus()` (confirmed live —
  `Keys.onEscapePressed` never fires). Shift-state is read off mouse-event
  modifiers instead of a key handler (pointer events carry accurate
  modifiers regardless of focus), and cancel is bound to right-click instead
  of Escape.
- **Grid drag-snap semantics matter a lot for feel.** Snapping the *live
  preview* rectangle to gridlines makes small drags produce no visible
  feedback and the start corner appears to "jump." Only snap on release; the
  live preview tracks the raw, unsnapped rectangle. Snapping floors the low
  edge / ceils the high edge (outward, enclosing), not round-to-nearest —
  rounding asymmetrically drops the start/end cell depending on which half
  of the cell the press/release landed in.
- **`QCursor`-style unreliability doesn't apply here** — `Workspace.cursorPos`
  is the privileged, always-accurate cursor position; no equivalent of the
  old daemon's "QCursor::pos() has no focused surface" problem exists inside
  a KWin script.
- **`KWin.PlacementArea`** is the `Workspace.clientArea(...)` option that
  actually excludes panel/dock struts — use it, not the raw output geometry,
  for anything that shouldn't overlap the taskbar.
- **Testing drags synthetically**: `ydotool mousemove --absolute` is
  miscalibrated on this system (events cluster near origin regardless of
  target). Use relative `ydotool mousemove -x -y` instead. That said, prefer
  asking the user to test live via the shortcut over synthetic ydotool/
  screenshot testing — it's faster and more token-efficient for both sides.
- Background test processes (ydotoold, ad-hoc D-Bus probes) should be run via
  the Bash tool's `run_in_background: true`, not manual `&`/`disown` — the
  latter has been unreliable here (spurious exit 144, process not surviving).
- Restarting `plasma-kwin_wayland.service` drops the Wayland socket and
  crashes every running app — always get fresh explicit confirmation before
  doing it, even if it was approved earlier in the same session.

## Config schema

`~/.config/kwinrc`, section `[Script-divvygrid14]` (all entries optional,
missing = kcfg default). Edit via System Settings → Window Management → KWin
Scripts → DivvyGrid → Configure..., or by hand with `kwriteconfig6`:

| entry | type | default | notes |
|---|---|---|---|
| `gridCols` | Int | 6 | |
| `gridRows` | Int | 4 | |
| `mode` | Int | 0 | 0=fullscreen, 1=compact — see combo-box gotcha above |
| `compactWidth` | Int | 480 | px |
| `compactHeight` | Int | 300 | px |
| `gap` | Int | 8 | px inset applied to each edge of the final placed window |
| `resizeOverlapping` | Bool | true | shrink other windows whose edge is fully covered by a new placement |
| `compactAtCursor` | Bool | false | compact mode: spawn overlay centered on the mouse cursor |
| `hotCorner` | Int | 0 | 0=none,1=topLeft,2=topRight,3=bottomLeft,4=bottomRight, wired to a `ScreenEdgeHandler` per corner in `main.qml`, gated by `enabled: root.hotCorner === "..."` so only one is ever active |
| `monitorsJson` | String | `{}` | JSON map of output name → `{gridCols, gridRows}` override, e.g. `{"DP-2":{"gridCols":8,"gridRows":6}}` |
| `dragAutoTrigger` | Bool | false | auto-show a top-center picker on any native window drag past a distance threshold, no shortcut needed — see "Auto-trigger on drag" below |
| `autoAtCursor` | Bool | false | auto-trigger picker spawns trailing the cursor's drag motion — the cursor lands at the corner facing opposite the drag direction (so continuing to drag moves the cursor *away* from the picker rather than into it). Centering or fixed corner anchoring both force every selection to include the cursor's spawn cell, making single-cell picks at other cells impossible on a 1×1 picker. Also: leaving the picker clears the auto-mode anchor, so releasing past the edge does NOT commit a resize. Independent of `compactAtCursor` (which only affects non-autoMode compact activations) |

The global shortcut (default Meta+Alt+D) is owned by `ShortcutHandler` in
`Shortcuts.qml`, rebindable from System Settings → Shortcuts — it's not a
kcfg config entry.

## Drag-triggered activation (shortcut mid-drag)

Holding the shortcut while native-dragging a window retargets the overlay at
that window and follows the mouse for the rest of the drag (`main.qml`'s
`dragTriggered` state, `show(forcedTarget)`, `externalCanvasPoint()`,
`onNativeDragStarted/Stepped/Finished`, `hookWindow()`). Always forces
`overlayMode = "fullscreen"` regardless of the configured mode — compact's
small cursor-centered box made the "selection must include the shortcut's
anchor point" restriction too cramped; fullscreen has enough room to reach
most layouts anyway. This was an explicit product decision, not a
placeholder — don't "fix" it by trying to make compact mode work here
without raising it first.

## Auto-trigger on drag (`dragAutoTrigger`)

Opt-in: shows a small top-center picker on *any* native window drag, no
shortcut held — modeled on KZones/MouseTiler's automatic drag-triggered zone
overlays, but architecturally distinct from drag-triggered activation above
(no key involved at all). Relevant `main.qml` state/functions: `autoMode`,
`autoDragPending`/`autoDragStartPos`/`autoDragThreshold` (24px), `autoAnchored`,
`showAuto()`, `pointInCanvas()`, and the `autoMode` branches inside
`onNativeDragStarted/Stepped/Finished`.

- **Trigger**: `onNativeDragStarted` (already hooked on every window via
  `hookWindow`/`onWindowAdded`) arms `autoDragPending` if `dragAutoTrigger` is
  on and no overlay is already visible. `onNativeDragStepped` checks the
  cursor's distance from the drag's start position each step; once past
  `autoDragThreshold`, it calls `showAuto(win)`. The threshold exists so a
  plain click-to-focus or tiny nudge doesn't flash the picker.
- **Positioning**: fixed top-center of the screen the drag is currently on
  (not cursor-following) — `canvasX`/`canvasY` have an `autoMode` branch
  ahead of the normal `compactAtCursor`/`dragTriggered` cursor-anchoring
  logic. `isCompact` is `true` whenever `autoMode` is true (forces the
  compact-sized box regardless of the configured `mode`).
- **Multi-cell selection without a real drag gesture**: only one point is
  ever available (the native drag position — the overlay's own `MouseArea`
  receives no events during a native move, same limitation as
  drag-triggered activation above), so there's no independent
  press-then-drag-then-release the way the shortcut-driven grid gets one for
  free. Instead: nothing is selected until the cursor first crosses into the
  picker's bounds (`pointInCanvas()`); that crossing point becomes a pinned
  anchor (`dragStart`), `autoAnchored` flips true, and `root.dragging` is set
  so the existing `rawRect()`/`computeSelBounds()`/`finishDrag()` machinery
  takes over unmodified — continuing to drag grows a real rectangle between
  the anchor and the live cursor position, visually identical to the
  shortcut-driven grid. If the cursor never enters the picker before
  release, nothing commits — the native move already applied itself, so
  "cancel" here just means "hide and get out of the way," never "undo."
- **Multi-monitor**: the picker is pinned to whichever screen the drag
  started on but has to follow the cursor across monitors — each
  `onNativeDragStepped` call re-derives the current screen via
  `screenAt(Workspace.cursorPos)` and, if it changed, re-homes `screenGeo`/
  `availGeo`/`activeGridCols`/`activeGridRows` (same per-monitor-override
  lookup `show()`/`showAuto()` do initially) and drops any in-progress
  anchor/selection, since it was expressed in the old screen's local
  coordinates and doesn't translate. The picker then has to be re-anchored
  on the new screen.
- Title bar and window-switcher picker are intentionally suppressed in this
  mode (`showAuto()` leaves `targetTitle`/`targetIconName` empty) — the
  target window is unambiguous (it's exactly the one being dragged), so that
  chrome would be pure noise here.

## Not yet done / known gaps

- No theme awareness or drop shadow on the overlay (flat colors only).
- Drag-triggered activation (shortcut mid-drag, above) doesn't re-home
  across monitors mid-drag the way the newer auto-trigger-on-drag picker
  does — it was never reported as an issue there, so it hasn't been fixed,
  but the same fix (screen re-derivation in `onNativeDragStepped`) would
  apply if it ever comes up.
