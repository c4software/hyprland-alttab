# hyprland-alttab — Omarchy shell plugin

Alt+Tab switcher in QML, hosted as a `service` plugin inside the
`omarchy-shell` (Quickshell) process: a single persistent process, no daemon,
no socket, no autostart to manage.

## Requirements

- Omarchy with the Quickshell shell (`omarchy-shell`)
- Hyprland ≥ 0.56 (Lua config)

## Installation

> The `manifest.json` lives at the repo root (required by `omarchy plugin add`),
> with `entryPoints` pointing to `omarchy-plugin/Service.qml`.

1. Install and enable:

```sh
omarchy plugin add https://github.com/c4software/hyprland-alttab --enable
```

For local development, link a working copy instead:

```sh
ln -sfn ~/projets/hyprland-alttab ~/.config/omarchy/plugins/vbrosseau.alttab
omarchy plugin enable vbrosseau.alttab
```

2. Bindings — include [`alttab-bindings.lua`](alttab-bindings.lua) from
   `~/.config/hypr/customisation.lua` (or `bindings.lua`), so plugin updates
   apply without touching your config:

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/vbrosseau.alttab/omarchy-plugin/alttab-bindings.lua")
```

   If the plugin starts without finding the binding, it shows a notification
   (clicking it opens this README). Detection relies on the `"Alt-Tab switcher"`
   bind description — keep it if you customize the keys.

3. `omarchy restart shell`, then `hyprctl reload` and check
   `hyprctl configerrors`. The shortcut must show up in
   `hyprctl globalshortcuts`.

Plugin code changes reload automatically
(`omarchy-shell shell rescanPlugins` to force).

## Manual test

```sh
hyprctl dispatch 'hl.dsp.global("omarchy-alttab:next")'   # opens the overlay
```

## Configuration

Optional `~/.config/omarchy/alttab.json`, picked up live:

```json
{ "previews": false }
```

- `previews` (default `true`): `false` shows app icons instead of window
  previews; `true` (or deleting the file) turns them back on. Pressing `P`
  while the overlay is open toggles it and saves the choice to this file.

## Behavior

- ALT+Tab / SUPER+Tab: opens the overlay, pressing again advances the selection.
- Tab/Right → next, Shift+Tab/Left → previous, Enter → activate,
  Escape → close without focusing, releasing ALT/SUPER → activate,
  P → toggle window previews / app icons.
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
  (focusHistoryID), pinned windows excluded.
- Colors: the shell's `Color` singleton (`qs.Commons`) — follows the Omarchy
  theme automatically.
