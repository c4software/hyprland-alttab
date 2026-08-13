# hyprland-alttab — legacy Rust implementation

Standalone GTK4 layer-shell switcher, superseded by the
[Omarchy shell plugin](../omarchy-plugin/) and kept for reference.

> Not part of the plugin. Nothing here is installed or executed by the plugin —
> these are manual steps for anyone who wants to build the old binary.

## Build

Requires the GTK4 and layer-shell libraries plus a Rust toolchain
(`gtk4`, `gtk4-layer-shell`, `rust` on Arch Linux — install them with your
distribution's package manager).

```bash
cd rust && cargo build --release
cp target/release/alttab ~/.local/bin/alttab
```

C libraries needed for linking:

- `libgtk-4.so` — GTK 4
- `libgtk4-layer-shell.so` — Wayland layer-shell protocol for GTK4

## CLI

```
alttab                      Starts the daemon if needed, sends "tab" (bind this)
alttab --daemon             Starts the daemon in the background
alttab --show               Shows the GTK4 switcher (one-shot)
alttab --kill               Stops the daemon
alttab --focus-address ADDR Focus a window by Hyprland address
```

Hyprland binding (exec form):

```lua
o.bind("ALT + TAB", nil, "alttab", { repeating = true })
```

## Architecture

```
rust/src/
├── main.rs       — CLI argument dispatch
├── ipc.rs        — Hyprland IPC (Lua dispatchers) via Unix socket
├── daemon.rs     — daemon mode (socket server, spawn-guard)
├── theme.rs      — reads colors from colors.toml
├── windows.rs    — fetches and sorts Hyprland windows
└── ui.rs         — GTK4 layer-shell overlay
```

Runtime files under `$XDG_RUNTIME_DIR`: `hypr-alttab.sock`,
`hypr-alttab-switcher.sock`, `hypr-alttab-daemon.pid`, `hypr-alttab-switcher.pid`.

Focus uses the Lua dispatcher (`hl.dsp.focus({ window = "address:…" })`), which also
switches workspaces — Hyprland ≥ 0.56 rejects the old text syntax. Theme colors come
from `~/.local/state/omarchy/current/theme/colors.toml`
(`background` / `accent` / `foreground`).

## Notable points

**No threads in the UI** — the switcher's socket listener runs via non-blocking polling
with `glib::timeout_add_local` (every 16 ms), avoiding `Send` constraints on GTK objects.

**State sharing** — all mutable UI state lives in `Rc<Cell<>>` / `Rc<RefCell<>>`; shared
callbacks are `Rc<dyn Fn()>` cloned into each event handler.

**Layer-shell via trait** — `gtk4-layer-shell` 0.8 exposes its interface as the
`LayerShell` trait rather than free functions.

**`gio-unix` for icons** — `DesktopAppInfo` moved out of `gio` in 0.22 and must be
imported from `gio_unix`.
