# DivvyGrid

A Divvy-style click-drag grid window tiler for **KDE Plasma 6 / KWin on Wayland**.

Hold a global shortcut (default **Meta+Alt+D**) — a grid overlay appears — drag
a rectangle across cells — release — the previously-active window snaps to that
region.

Inspired by [Divvy](https://mizage.com/divvy/) and FancyZones, implemented as a
**declarative KWin script** with no Qt/KF build dependencies: just symlink one
directory into `~/.local/share/kwin/scripts/` and enable it.

## Features

- **Three activation modes**
  - **Global shortcut** (`Meta+Alt+D`, rebindable) spawns a fullscreen or compact
    grid overlay for the active window.
  - **Mid-drag** — hold the shortcut *while* dragging a window and the overlay
    retargets that window and follows the mouse for the rest of the drag.
  - **Auto-trigger** (opt-in) shows a picker after any native window drag past a
    distance threshold — no shortcut held at all.
- **Shift to double resolution** at drag time for fine-grained placement.
- **Hot-corner activation** — drag from a configured screen corner to spawn the
  overlay.
- **Compact overlay** mode for small grids and small screens, with optional
  cursor-anchored spawn.
- **Full-size ghost preview** — while selecting in the compact grid, a
  translucent outline of the final window rectangle is drawn 1:1 on the real
  screen, so a selection in the miniature grid still shows you exactly what
  you'll get.
- **Auto-trigger picker spawns trailing the cursor's drag motion** — drag away
  from the picker rather than into it. Leaving the picker clears the selection
  anchor, so a release past the edge doesn't commit a phantom resize.
- **Per-monitor grid overrides** via JSON map (e.g. a 4K portrait side monitor
  can run a 2×6 grid while the main stays at 6×4).
- **Multi-monitor follow** — the auto-trigger picker re-homes to whichever
  screen the dragged window is currently on, with per-screen grid sizes.
- **Resize-overlap** — when committing to cells that overlap existing windows,
  shrink those windows instead of stacking.
- **Covered-window relocation** — a placement that hides another window
  completely pushes that window to the largest free grid region instead of
  leaving it buried, or swaps it into the slot the placed window just vacated
  when nothing is free.
- **Linked resize** (opt-in) — Windows-Snap-style: drag the border between two
  tiled windows and both follow, so a shared edge behaves like a splitter. Works
  across a whole row or column of windows, not just the pair either side of the
  cursor, and respects each window's declared minimum/maximum size.
- **Theme-aware overlay** — colors track the active Plasma color scheme (the
  same set Plasma's own OSDs use), so it follows Breeze Dark/Light or any custom
  scheme with no configuration.
- **100% declarative QML** running inside `kwin_wayland` directly — no compiled
  binary, no D-Bus, no injected scripts.

## Usage

| Action | Result |
|---|---|
| Hold `Meta+Alt+D`, drag across cells, release | active window snaps to that region |
| Hold `Shift` while dragging | doubles the grid resolution for a finer placement |
| **Right-click** | cancels the overlay |
| Hold the shortcut *during* a window drag | overlay retargets the dragged window |

Cancel is right-click rather than `Escape` deliberately: script-owned overlay
windows never reliably receive real keyboard focus under KWin, so a key handler
can't be counted on. Shift state is read from mouse-event modifiers for the same
reason.

The live preview rectangle tracks the raw cursor, not the gridlines — it only
snaps on release, so small drags still give visible feedback and the start
corner never appears to jump. Snapping encloses outward (floors the low edge,
ceils the high edge) rather than rounding to nearest, so the cells you pressed
and released in are always both included.

## Installation

### From a `.kwinscript` bundle (recommended for users)

1. Download [`divvygrid.kwinscript`](https://github.com/Ivan-Malinovski/divvygrid/releases/latest).
2. **System Settings** → **Window Management** → **KWin Scripts**.
3. Click **"Install from File..."** at the bottom of the dialog, pick the file.
4. Enable **DivvyGrid** in the list.
5. (Optional) Rebind `Meta+Alt+D` in **System Settings → Shortcuts** if you want
   a different key — it's a regular KWin shortcut, fully rebindable.

### From source (developer install)

```sh
git clone https://github.com/Ivan-Malinovski/divvygrid.git
cd divvygrid
./install.sh
```

`install.sh` symlinks `kwinscript/` into `~/.local/share/kwin/scripts/`,
enables it, and reconfigures KWin. Idempotent — safe to re-run.

## Configuration

Open **System Settings → Window Management → KWin Scripts → DivvyGrid →
Configure...**.

| Setting | Default | Notes |
|---|---|---|
| `gridCols` / `gridRows` | 6 / 4 | base grid size |
| `mode` | fullscreen | fullscreen or compact overlay |
| `compactWidth` / `compactHeight` | 480 / 300 | compact overlay size (px) |
| `gap` | 8 | px inset applied to each edge of the final placed window |
| `resizeOverlapping` | true | shrink overlapping windows on commit |
| `relocateCovered` | true | move fully covered windows to the largest free grid region |
| `linkedResize` | false | co-resize windows sharing the dragged edge |
| `compactAtCursor` | false | compact mode spawns at the cursor |
| `hotCorner` | none | topLeft / topRight / bottomLeft / bottomRight |
| `monitorsJson` | `{}` | per-output grid overrides, JSON map |
| `dragAutoTrigger` | false | auto-show picker on any native window drag |
| `autoAtCursor` | false | auto-trigger picker spawns trailing the cursor's drag direction |

The global shortcut (default `Meta+Alt+D`) is owned by KWin and rebindable from
**System Settings → Shortcuts**, same as any other KWin shortcut.

## Development

### Editing `main.qml`

KWin caches compiled QML per plugin ID for the life of the `kwin_wayland`
process. Editing `main.qml` in place and reconfiguring is **not enough** —
the plugin ID has to be bumped so KWin sees a "new" script and recompiles.

```sh
./bump.sh         # bumps to the next divvygrid<N>, migrates kwinrc settings, reloads
```

`bump.sh` walks the symlinks in `~/.local/share/kwin/scripts/`, picks the next
free `divvygrid<N>`, rewrites `metadata.json`, copies every per-script config
key forward under the new `[Script-<newId>]` section, unloads the old script,
and verifies the new one loads. Does **not** touch `plasma-kwin_wayland.service`,
so no Wayland apps are killed.

### Building a release bundle

```sh
./build.sh        # produces divvygrid.kwinscript (canonical ID "divvygrid")
```

`build.sh` produces the `.kwinscript` bundle with the canonical non-numeric
plugin ID `divvygrid`, suitable for distribution. Your live dev install (on
the current numbered ID) is unaffected; `bump.sh` continues to work on it
between releases.

> **Two gotchas when installing the bundle alongside an existing dev install:**
> 1. Don't enable both `divvygrid` and `divvygrid<N>` at the same time — both
>    register a `ShortcutHandler` under the same name in `kglobalaccel`'s
>    `kwin` component, producing a shortcut-ownership race (whichever loaded
>    second wins the Meta+Alt+D grab, nondeterministically).
> 2. Don't consolidate the live dev install to the canonical `divvygrid` —
>    the per-plugin-ID compiled-QML cache means KWin may serve a stale
>    compiled version for a reused ID; a clean reset needs a full
>    `plasma-kwin_wayland.service` restart, which crashes every running
>    Wayland app. The numbered-ID dev workflow exists specifically to keep
>    that restart off the table.

### Architecture

Everything runs inside `kwin_wayland` via the Plasma 6 declarative KWin script
API (`X-Plasma-API: declarativescript`), with privileged access to `Workspace.*`
— no D-Bus, no injected scripts, no separate daemon. The entire overlay lives in
`kwinscript/contents/ui/main.qml` (grid, drag, snap, compact mode, multi-monitor
picker, hot corner, drag-triggered activation, auto-trigger-on-drag picker,
linked resize, covered-window relocation).
Per-screen configuration and shortcut handling are split into small components
under `kwinscript/contents/ui/components/`.

## License

[MIT](LICENSE)
