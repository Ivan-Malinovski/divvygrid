# DivvyGrid

A Divvy-style click-drag window tiler for KDE Plasma 6 / KWin on Wayland. Hold a
global shortcut (default Meta+Alt+D), a fullscreen (or compact) grid overlay
appears, drag a rectangle across grid cells, release, and the previously-active
window snaps to that region.

## Architecture

- **`main.cpp`** — the persistent background daemon (`QGuiApplication`, no
  window shown until toggled). Registers a `KGlobalAccel` global shortcut,
  owns the one recreatable overlay `QQuickWindow`, and does two things no
  ordinary Wayland client can do by itself, via one-shot KWin script injection
  over D-Bus (`org.kde.kwin.Scripting.loadScript`/`run`/`unloadScript`):
  1. Reads `workspace.activeWindow` (the window to resize) and
     `workspace.cursorPos` (real global pointer position — see gotchas below).
  2. Applies the final `frameGeometry` to that window on commit.
  KWin scripts have no file/config API, so they report back via
  `callDBus(...)` into `AppService` (`org.divvygrid.App` at `/App`), exported
  over the session bus.
- **`~/.local/share/divvygrid/main.qml`** — the overlay UI itself: a
  transparent, borderless `LayerShellQt` layer-shell surface
  (`org.kde.layershell`, layer `Overlay`) covering one screen. Draws the grid,
  handles the drag (raw/unsnapped rect for live preview, floor/ceil-snapped
  rect only computed on release — see gotchas), and calls back into C++
  (`controller.commit(...)`/`controller.cancel()`).
- **`~/.config/divvygrid/config.json`** — user config, written with defaults
  on first run, read once at daemon startup (`loadConfig()` in `main.cpp`).
  Changing it requires restarting the daemon.
- **Settings GUI** (`divvygrid-settings`, if present) — a small Qt app to
  edit `config.json` without hand-editing JSON, and to restart the daemon so
  changes take effect.
- **Autostart**: `~/.config/autostart/divvygrid.desktop` launches the daemon
  at login. `~/.local/share/applications/divvygrid.desktop` is the
  launcher-menu entry (`NoDisplay=true` on both — it's a background service,
  not meant to be opened directly, except the settings GUI).

## Build & deploy

Qt6/KF6 dev headers aren't installed on the host — build inside the toolbox
container `divvygrid-build`:

```
toolbox run -c divvygrid-build cmake -S /home/ivan/dev/divvygrid -B /home/ivan/dev/divvygrid/build
toolbox run -c divvygrid-build cmake --build /home/ivan/dev/divvygrid/build -j$(nproc)
```

Deploy and restart the daemon (must kill the old process first — `cp` onto a
running binary fails with "Text file busy"):

```
pkill -f /home/ivan/.local/bin/divvygrid
# confirm it's actually gone (pgrep -f divvygrid) before cp, killing is async
cp /home/ivan/dev/divvygrid/build/divvygrid ~/.local/bin/divvygrid
/home/ivan/.local/bin/divvygrid &
```

`main.qml` is loaded from disk by absolute path at runtime — no rebuild
needed for QML-only edits, just restart the daemon.

## Gotchas / lessons learned

- **QML console.log is invisible by default** even with
  `QT_FORCE_STDERR_LOGGING=1`. You also need
  `QT_LOGGING_RULES="*.debug=true"` set, or nothing shows up anywhere
  (not stdout, not journalctl).
- **`QCursor::pos()` is unreliable on Wayland** for a background client
  reacting to a global shortcut — it has no focused surface at that moment.
  Don't use it to decide which monitor to show the overlay on; instead read
  `workspace.cursorPos` via the same privileged KWin-script D-Bus callback
  used to capture the active window (see `reportState`/`gCursorPos`).
- **wlr-layer-shell binds a surface to one output at creation time** and it
  cannot be migrated afterward — `QWindow::setScreen()` on an already-shown
  layer-shell window is a no-op for moving it to a different monitor. The
  daemon must destroy and recreate the `QQuickWindow` (via `QQmlComponent`,
  not `engine.load()`) whenever the target screen changes.
- **Grid drag-snap semantics matter a lot for feel.** Snapping the *live
  preview* rectangle to gridlines makes small drags produce no visible
  feedback and the start corner appears to "jump." Only snap on release; the
  live preview should track the raw, unsnapped rectangle. And snapping should
  floor the low edge / ceil the high edge (outward, enclosing), not round to
  nearest — rounding asymmetrically drops the start/end cell depending on
  which half of the cell the press/release landed in.
- **Testing drags synthetically**: `ydotool mousemove --absolute` is
  miscalibrated on this system (events cluster near origin regardless of
  target). Use relative `ydotool mousemove -x -y` instead.
- Background test processes (ydotoold, ad-hoc D-Bus probes) should be run via
  the Bash tool's `run_in_background: true`, not manual `&`/`disown` — the
  latter has been unreliable here (spurious exit 144, process not surviving).

## Config schema

`~/.config/divvygrid/config.json` (all fields optional, missing = default):

```json
{
  "mode": "fullscreen",       // "fullscreen" | "compact"
  "compactWidth": 480,
  "compactHeight": 300,
  "gap": 8,                   // px inset applied to each edge of the final placed window
  "shortcut": "Meta+Alt+D",   // Qt portable-text QKeySequence string
  "gridCols": 6,
  "gridRows": 4,
  "monitors": {                // per-monitor grid override, keyed by QScreen::name() (e.g. "DP-2")
    "DP-2": { "gridCols": 8, "gridRows": 6 }
  }
}
```

Edit it by hand, or use the `divvygrid-settings` GUI (`settings/settings_main.cpp`, a
separate QtWidgets executable, CMake target `divvygrid-settings`, deliberately not
sharing code with the daemon — only the on-disk JSON schema). It also toggles
`~/.config/autostart/divvygrid.desktop`'s `Hidden=` line for a login-autostart
checkbox, and can restart or quit the daemon (`pkill -f ".../divvygrid$"` — note
the `$` anchor: an unanchored pattern also matches `divvygrid-settings`'s own
command line since it's a substring prefix).

## Not yet done / known gaps

- No undo/restore for a placement once committed.
- No theme awareness or drop shadow on the overlay (flat colors only).
- `shortcut` string parsing (`QKeySequence(str)`) is untested against unusual key
  combos beyond the default — the settings GUI captures it live via
  `QKeySequenceEdit` and serializes with `QKeySequence::PortableText`, which
  should round-trip, but hasn't been exercised end-to-end interactively.
