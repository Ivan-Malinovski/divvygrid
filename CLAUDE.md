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
  `X-KDE-PluginKeyword` (currently `"divvygrid6"`, see "Plugin ID" below) is
  both the kwinrc config-group key (`[Script-<id>]`) and the cache key for
  KWin's in-process compiled-QML cache.
- **`kwinscript/contents/ui/main.qml`** — the entire overlay: grid, drag/snap,
  compact mode, title bar, multi-monitor window picker, shift-to-double grid
  resolution, overlap-resize on commit. Root is a `PlasmaCore.Dialog` (not a
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
  entry, auto-bound into `~/.config/kwinrc` under `[Script-divvygrid6]`.
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

Symlink the package directory in (one-time):

```
ln -s /home/ivan/dev/divvygrid/kwinscript ~/.local/share/kwin/scripts/divvygrid6
kwriteconfig6 --file kwinrc --group Plugins --key divvygrid6Enabled true
qdbus-qt6 org.kde.KWin /KWin reconfigure
```

- **`config.ui` / `main.xml` changes**: take effect immediately — just reopen
  System Settings' "Configure..." dialog for the script, no reload needed.
- **`main.qml` changes**: KWin's declarative scripting engine caches compiled
  QML per plugin ID for the life of the `kwin_wayland` process, so editing
  `main.qml` in place and reconfiguring is **not** enough — see "Plugin ID
  cache-busting" below.
- Binary for D-Bus CLI calls is `qdbus-qt6` (also available as `qdbus`) —
  `qdbus6` does not exist on this system.

### Plugin ID cache-busting

To force a fresh QML recompile after editing `main.qml`, bump the plugin ID
(`Id` and `X-KDE-PluginKeyword` in `metadata.json`, e.g. `divvygrid6` →
`divvygrid7`), symlink a fresh `~/.local/share/kwin/scripts/<newId>` pointing
at the same `kwinscript/` directory, enable the new ID, **fully disable and
remove the old one**, then `unloadScript` (old id) + `reconfigure` via D-Bus.

This has two real costs, not just cosmetic ones — learned the hard way:

- kcfg config is stored per-plugin-ID section in kwinrc
  (`[Script-divvygrid7]`), so every bump loses previously-set values under
  the old section name. Re-apply anything that mattered (or copy the keys
  across with `kwriteconfig6` before disabling the old ID).
- If the old ID isn't fully disabled/removed, it stays enabled alongside the
  new one and both register a `ShortcutHandler` under the identical name
  ("DivvyGrid: Show overlay") in the same `kglobalaccel` "kwin" component —
  a genuine shortcut-ownership race, not just a duplicate System Settings
  row. Whichever script currently holds the grab responds to Meta+Alt+D,
  nondeterministically.

Current plugin ID is `divvygrid6` (bumped several times during development;
consolidating back to the canonical `"divvygrid"` string is still pending —
do it only with fresh explicit approval, since guaranteeing a clean cache
reset for that reused ID likely needs a full `plasma-kwin_wayland.service`
restart, which kills every running Wayland app).

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

`~/.config/kwinrc`, section `[Script-divvygrid6]` (all entries optional,
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
| `hotCorner` | Int | 0 | 0=none,1=topLeft,2=topRight,3=bottomLeft,4=bottomRight — config value only, not yet wired to a `ScreenEdgeHandler` (see Not yet done) |
| `monitorsJson` | String | `{}` | JSON map of output name → `{gridCols, gridRows}` override, e.g. `{"DP-2":{"gridCols":8,"gridRows":6}}` |

The global shortcut (default Meta+Alt+D) is owned by `ShortcutHandler` in
`Shortcuts.qml`, rebindable from System Settings → Shortcuts — it's not a
kcfg config entry.

## Not yet done / known gaps

- **Hot corner isn't wired up.** `hotCorner` is read into config and mapped
  to a name, but nothing in `main.qml` registers a `ScreenEdgeHandler` or
  otherwise acts on it yet.
- **Drag-triggered activation isn't ported.** Holding the shortcut mid-native
  -window-drag to retarget the overlay to the dragged window (a daemon-era
  feature) doesn't exist in the script yet. Needs
  `interactiveMoveResizeStarted/Stepped/Finished` hooked directly on window
  objects, feeding the same `dragging`/`dragCurrent` state the mouse-driven
  path already uses.
- No `install.sh` yet — deploy manually per "Deploy / reload" above.
- No undo/restore for a placement once committed.
- No theme awareness or drop shadow on the overlay (flat colors only).
- The old daemon (`main.cpp`, root-level `main.qml`, `settings/`,
  `CMakeLists.txt`) is still in the repo as a fallback but is unmaintained
  going forward and should be deleted once the script has been used for real
  for a while.
