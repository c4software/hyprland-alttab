# hyprland-alttab — Omarchy shell plugin

Alt+Tab switcher in QML, hosted as a `service` plugin inside the
`omarchy-shell` (Quickshell) process: a single persistent process, no daemon,
no socket, no autostart to manage.

## Files

- `Service.qml` — entry point: state, settings, shortcuts, window list, open/close
- `Overlay.qml` — the overlay window: keyboard, tiles, hover
- `IconResolver.qml` — window icons (desktop entries, web apps, terminal apps, agents)
- `Highlight.qml` — on-screen highlight of the selection (`highlight` setting)
- `logic.js` — pure helpers (settings, grouping, matching)
- `modules/` — optional features

## Requirements

- Omarchy with the Quickshell shell (`omarchy-shell`)
- Hyprland ≥ 0.56 (Lua config)

## Installation

> The `manifest.json` lives at the repo root (required by `omarchy plugin add`),
> with `entryPoints` pointing to `omarchy-plugin/Service.qml`.

```sh
omarchy plugin add https://github.com/c4software/hyprland-alttab --enable
```

Nothing else to set up: the keybindings are registered by the plugin (see
[Keybindings](#keybindings)).

For local development, link a working copy instead:

```sh
ln -sfn ~/projets/hyprland-alttab ~/.config/omarchy/plugins/vbrosseau.alttab
omarchy plugin enable vbrosseau.alttab
```

Plugin code changes reload automatically
(`omarchy-shell shell rescanPlugins` to force).

## Keybindings

The plugin evaluates [`alttab-bindings.lua`](alttab-bindings.lua) through
`hyprctl eval` when its `"Alt-Tab switcher"` binds are missing: at startup and
after each `configreloaded` event, since evaluated binds don't survive a
reload. Disabling the plugin (or setting `"bindings": false`) runs
`hyprctl reload` to restore the binds from your config. If the binds still
can't be found after evaluating the file, it shows a notification (clicking it
opens this README). The shortcut shows up in `hyprctl globalshortcuts`.

A config that still includes the file (earlier versions) keeps working: the
binds are found and the plugin registers nothing. The line can be removed:

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/vbrosseau.alttab/omarchy-plugin/alttab-bindings.lua")
```

## Manual test

```sh
hyprctl dispatch 'hl.dsp.global("omarchy-alttab:next")'   # opens the overlay
```

## Configuration

Optional `~/.config/omarchy/alttab.json`, picked up live:

```json
{ "previews": true, "modules": { "notificationBadges": false } }
```

- `previews` (default `false`): `true` shows window previews instead of app
  icons; `false` (or deleting the file) goes back to icons. Pressing `P`
  while the overlay is open toggles it and saves the choice to this file.
- `bindings` (default `true`): `false` stops the plugin from registering
  `alttab-bindings.lua`, for those who bind `hl.dsp.global("omarchy-alttab:next")`
  and `hl.dsp.global("omarchy-alttab:prev")` themselves (also define the
  `alttab` submap with an `ESCAPE` exit, the overlay enters it while open).
- `highlight` (default `false`): while the overlay is open, the selected
  window gets an accent border, the other listed windows are faded, and the
  workspace shown follows the selection, all through Hyprland window rules
  and tags, without moving focus. Pressing `F` toggles it and saves the
  choice to this file. Only workspaces of the monitor the switcher opened on
  are followed; hidden group tabs show no highlight. If
  the shell dies mid-switch, the shown workspace is not restored.
- `fadeOpacity` (default `80`): opacity of the faded windows, in percent
  (10–100).
- `fadeDuration` (default `250`): duration of the fade, in milliseconds
  (0–2000, `0` disables the animation).
- `modules`: optional features living in [`modules/`](modules), each on or
  off by id; a disabled module is not loaded at all.
  - `notificationBadges` (default `true`): a red dot on windows whose app sent a
    notification since you last looked at it, read from omarchy-shell's
    notification files (on-screen toasts and history). The app name is
    matched against the window class like `omarchy-hyprland-focus-app` does.
    Browsers notify under their own name, so for them the site Chromium puts
    first in the body (`web.whatsapp.com`) is matched against web app windows
    (`chrome-web.whatsapp.com__-Default`); a regular tab gets no badge.

Omarchy only offers a settings UI (manifest `schema`) to bar widgets, so a
`service` plugin like this one keeps its options in its own file.

## Behavior

- ALT+Tab / SUPER+Tab: opens the overlay, pressing again advances the selection.
- Tab/Right → next, Shift+Tab/Left → previous, Enter → activate,
  Escape → close without focusing, releasing ALT/SUPER → activate,
  P → toggle window previews / app icons, F → toggle the window highlight,
  Q → close the selected window.
- ALT/SUPER+Shift+Tab: opens the overlay on the last window of the list,
  pressing again steps backward.
- The overlay stays open as long as ALT or SUPER is physically held
  (checked via `hl.is_key_down` when no keyboard event reaches the
  overlay — the case of Tab released before the keyboard is acquired).
- Mouse: hover selects (once the pointer moves), click activates. Releasing
  ALT/SUPER always focuses the selection, wherever the pointer is.
- Each window shows a still preview (one screencopy frame per opening, never
  streamed), sized to its aspect ratio and shrunk to fit the monitor; the app
  icon is shown instead when capture is unavailable or previews are disabled.
- Windows grouped by workspace (active first), sorted by recency
  (focusHistoryID), pinned windows and special workspaces (`special:*`,
  scratchpad, Quake console) excluded.
- Colors: the shell's `Color` singleton (`qs.Commons`) — follows the Omarchy
  theme automatically.
