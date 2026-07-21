# VibeTiles

A click-drag window tiler for KDE Plasma 6 / KWin on Wayland. Hold a global
shortcut (default Meta+Alt+D), a fullscreen (or compact) grid overlay
appears, drag a rectangle across grid cells, release, and the
previously-active window snaps to that region.

Ships as a **declarative KWin script** (`kwinscript/`) — no compiler, no
Qt6/KF6 dev headers, just symlink one directory into
`~/.local/share/kwin/scripts/` and enable it. An earlier standalone Qt6/KF6
daemon was deleted in `baad1e7`; some code comments still cite its
`main.cpp` line numbers as the origin of a ported algorithm (historical
attributions only, that file is gone).

## Architecture

Everything runs inside `kwin_wayland` via Plasma 6's declarative KWin script
API (`X-Plasma-API: declarativescript`) — a full `QQmlEngine` with
privileged, synchronous access to `Workspace.*`. No D-Bus, no daemon.

- **`kwinscript/metadata.json`** — KPackage metadata. `KPlugin.Id` /
  `X-KDE-PluginKeyword` is both the kwinrc config-group key
  (`[Script-<id>]`) and the cache key for KWin's compiled-QML cache — see
  "Deploy / reload".
- **`kwinscript/contents/ui/main.qml`** — the entire overlay: grid,
  drag/snap, compact mode, title bar, multi-monitor picker,
  overlap-resize/relocate on commit, hot corners, drag-triggered
  activation, auto-trigger-on-drag, linked resize, expand-to-fill. Root is
  `PlasmaCore.Dialog` (a plain `QtQuick Window` gets silently swallowed by
  the script host, confirmed live).
- **`kwinscript/contents/ui/components/Shortcuts.qml`** — `ShortcutHandler`s
  for the two global shortcuts, user-rebindable from System Settings →
  Shortcuts.
- **`kwinscript/contents/config/main.xml`** — kcfg schema, auto-bound into
  `~/.config/kwinrc`.
- **`kwinscript/contents/ui/config.ui`** — Qt Widgets settings form (Qt
  Designer XML), rendered by KWin's built-in script-config dialog
  (`kcm_kwin4_genericscripted`) — no compiled KCM needed.

## Deploy / reload

- **`./install.sh`** — first-time setup: symlinks `kwinscript/` into
  `~/.local/share/kwin/scripts/<id>`, enables it, reconfigures KWin.
  Idempotent.
- **`./bump.sh`** — run after **every** `main.qml` edit. KWin caches
  compiled QML per plugin ID, so editing in place and reconfiguring is not
  enough. Bumps `metadata.json` to the next `vibetiles<N>`, migrates every
  kwinrc key forward, disables + unloads the old ID, verifies the new one
  loads. Check `KPlugin.Id` in `metadata.json` for the current live value.
- **`./build.sh`** — produces `vibetiles.kwinscript`, a release bundle
  under the canonical (non-numeric) id `vibetiles`, for "Install from
  File...". Doesn't touch the numbered dev install. **Don't have both
  enabled at once** — they'd register the same-named `ShortcutHandler` and
  race for the Meta+Alt+D grab. Disable the dev id first.
- **`config.ui` / `main.xml` changes** take effect immediately — just
  reopen "Configure...". `main.qml` changes need `./bump.sh`.
- D-Bus CLI binary is `qdbus-qt6` (`qdbus6` does not exist here).
- Consolidating the dev id to the canonical `vibetiles` string is possible
  now (that namespace has never loaded, so no restart needed) but would
  forfeit cache-busting for future edits — get explicit approval first.

## Gotchas

- `QComboBox` auto-binds `currentIndex` (int), not `currentText` — type
  combo-backed kcfg entries (`mode`, `hotCorner`) as `Int` and map
  index→name manually in QML.
- `QPlainTextEdit` auto-binds `plainText` — used for `monitorsJson`.
- The generic KWin-script config dialog only does 1:1 scalar binding; no
  per-row/dynamic UI. Raw-JSON `QPlainTextEdit` is the zero-build tradeoff.
- Script-owned overlay windows never reliably get real keyboard focus
  (`Keys.onEscapePressed` never fires) — shift-state comes from mouse-event
  modifiers, cancel is bound to right-click.
- `ShortcutHandler` has no `enabled` property (fails component load if
  assigned) — its global grab lives for the script's whole lifetime, unlike
  `ScreenEdgeHandler` which does support live `enabled:` rebinding.
- A dead kglobalaccel registration still owns its key: renaming a
  `ShortcutHandler`'s `name:` strands the old action holding the shortcut,
  and a stored `none` binding is sticky (not restored by reload). Diagnose
  with `grep -i <name> ~/.config/kglobalshortcutsrc` /
  `qdbus-qt6 org.kde.kglobalaccel | grep -i <name>`; fix via
  `org.kde.KGlobalAccel.unregister` then rebind explicitly.
- Grid snap only applies on release, never to the live preview rect
  (snapping the preview kills small-drag feedback). Snap floors/ceils
  outward, never rounds. Exception: the compact-mode ghost draws from
  `snappedRect()` deliberately, to preview the exact committed outcome.
- `Workspace.cursorPos` is always accurate — no `QCursor` focused-surface
  caveat here.
- `KWin.PlacementArea` (not raw output geometry) excludes panel/dock
  struts.
- `console.log` is silently swallowed by the script host — use
  `console.warn`/`console.error`, read via
  `journalctl --user -b --no-pager | grep vibetiles`.
- The overlay itself is in `Workspace.stackingOrder` and (drag-triggered
  path) fullscreen, so any occupancy scan must filter it out.
  `normalWindow` isn't enough — it's true for the overlay too. Use the
  shared `isRealWindow()` predicate (keys off empty `resourceClass`) for
  *every* window scan; divergent filters between scans is how this bug hid
  before.
- Don't measure occupancy by summing per-window overlap areas —
  overlapping windows double-count and a region can read >100% occupied.
  `findFreeRegion`/`expandRectFor` test each obstacle independently in
  pixel/slot space instead (see below).
- `ydotool mousemove --absolute` is miscalibrated here; use relative
  `-x -y`. Prefer asking the user to test live via the shortcut over
  synthetic ydotool/screenshot testing.
- Run background test processes via Bash's `run_in_background: true`, not
  manual `&`/`disown` (unreliable here).
- Restarting `plasma-kwin_wayland.service` crashes every running Wayland
  app — always get fresh explicit confirmation first.

## Config schema

`~/.config/kwinrc`, section `[Script-<id>]` (see `KPlugin.Id` in
`metadata.json`; all entries optional, missing = kcfg default). Edit via
System Settings → Window Management → KWin Scripts → VibeTiles →
Configure..., or `kwriteconfig6`:

| entry | type | default | notes |
|---|---|---|---|
| `gridCols` | Int | 6 | |
| `gridRows` | Int | 4 | |
| `mode` | Int | 0 | 0=fullscreen, 1=compact |
| `compactWidth` | Int | 480 | px |
| `compactHeight` | Int | 300 | px |
| `gap` | Int | 8 | px inset applied to each edge of the final placed window |
| `resizeOverlapping` | Bool | true | shrink other windows whose edge is fully covered by a new placement |
| `relocateCovered` | Bool | true | move windows a placement *completely* covers to the largest free region |
| `compactAtCursor` | Bool | false | compact mode: spawn overlay centered on the mouse cursor |
| `hotCorner` | Int | 0 | 0=none,1=topLeft,2=topRight,3=bottomLeft,4=bottomRight |
| `monitorsJson` | String | `{}` | JSON map of output name → `{gridCols, gridRows}` override |
| `dragAutoTrigger` | Bool | false | auto-show a top-center picker on any native window drag past a distance threshold |
| `linkedResize` | Bool | false | co-resize windows sharing the dragged edge |
| `autoAtCursor` | Bool | false | auto-trigger picker spawns trailing the cursor's drag motion instead of fixed top-center |
| `autoExpandOnEdgeDrag` | Bool | false | Windows-Snap-style fill-on-edge-drop |

Two global shortcuts, not kcfg entries: Meta+Alt+D (`showOverlay`) and
Meta+Alt+E (`expandToGap`), both in `Shortcuts.qml`.

## Feature notes

- **Drag-triggered activation** — holding the shortcut mid-native-drag
  retargets the overlay at that window and follows the cursor
  (`dragTriggered`, `onNativeDrag*` in `main.qml`). Always forces
  fullscreen mode regardless of config — a deliberate product decision.
- **Auto-trigger on drag** (`dragAutoTrigger`) — a small top-center picker
  appears on any native drag past a 24px threshold, no shortcut needed.
  Selection needs the cursor to first cross into the picker bounds
  (`pointInCanvas`) to pin an anchor, since a native drag only ever
  delivers one point. Re-homes to a new screen mid-drag if the cursor
  crosses monitors.
- **Relocating covered windows** (`relocateCovered`) — a window a new
  placement *completely* covers (not just an edge slice) is moved instead
  of left hidden underneath. `findFreeRegion()` is pixel-accurate
  (coordinate-compression over obstacle edges in slot space, same
  technique as `expandRectFor`), not grid-quantized — off-grid gaps are
  measured at their true size. Falls back to the vacated slot
  (`snapRectToGrid`) if no free region is found; leaves the window in
  place (old behavior) if neither works.
- **Linked resize** (`linkedResize`) — dragging a window's edge moves the
  flush edge of every window in its contiguous border chain
  (`collectBorderChain`), like a shared splitter. Neighbours clamp to
  their own min/max size rather than blocking the drag. Pure side effect
  of `interactiveMoveResize*` signals; overlay never shown.
- **Expand to fill** (`expandToGap` / `autoExpandOnEdgeDrag`) — grows the
  active window into the free space around it without moving it.
  Meta+Alt+E expands in place; native edge-drop (drag a window against a
  screen edge with the mouse) fills the reachable gap with a shadowed
  preview. `expandRectFor()` is pixel-accurate (slot-space growth to the
  nearest obstacle edge, both axis orders tried, larger result kept).
  Deliberately scoped to the native mouse path only — it does not fire
  from a grid-overlay placement (`finishDrag`), which commits exactly the
  selected size.

## Theme awareness

Overlay colors track the active Plasma color scheme via
`Kirigami.Theme.colorSet: Complementary` (`mainItem`, same set Plasma's own
OSDs use) instead of being hardcoded. All colors reference
`Kirigami.Theme.*` properties, usually through the `themeAlpha(c, a)`
helper. `titleBar`/`pickerPanel`/compact-mode `canvas` get a `MultiEffect`
drop shadow; fullscreen `canvas` skips it (no edge to read a shadow
against).

## Not yet done / known gaps

- **Keyboard-only placement** (`Meta+Alt+Arrow` to move/grow a selection,
  `Meta+Alt+Return` to commit) was attempted and reverted — confirmed live
  that it didn't work, but the actual failure mode was never isolated. If
  revisited, instrument `onActivated` directly before assuming the
  planned data flow (reusing `dragStart`/`dragCurrent`/`dragging`) was
  itself at fault.
- Drag-triggered activation's mid-drag monitor re-homing restarts the
  selection on the new screen rather than preserving it — added
  speculatively, feel unvalidated.
