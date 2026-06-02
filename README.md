# hyprland-alttab

A visual **Alt+Tab window switcher** for the [Hyprland](https://hyprland.org/) Wayland compositor,
built as a GTK4 layer-shell overlay.

The same behavior is provided by two independent implementations — a **Rust** release binary and
a **Python** prototype — sharing an identical CLI and runtime protocol.

## Features

- 🪟 **Visual switcher** rendered through `gtk4-layer-shell` — no compositor plugin required
- 🖼️ **App icons** resolved from `.desktop` files (case / dash / dot variants, with `StartupWMClass` fallback)
- 🎨 **Themed** by reading colors from your Omarchy `mako.ini` (sensible defaults if absent)
- ⚡ **Single-command daemon** — first call spawns a long-lived daemon; later calls just send `tab` over a Unix socket
- 🧵 **Thread-free UI** (Rust) — socket polling runs on the GLib main loop via `glib::timeout_add_local`
- 📦 **Release builds** published automatically as Linux x86_64 binaries on tagged commits

## Install

Bind it in your Hyprland config and build the binary:

```conf
# ~/.config/hypr/hyprland.conf
bind = ALT, Tab, exec, alttab
```

```bash
# Arch
sudo pacman -S gtk4 gtk4-layer-shell rust
cd rust && cargo build --release
sudo cp target/release/alttab /usr/local/bin/
```

Or download a prebuilt binary.

## CLI

```
alttab              Start the daemon if needed, then signal "tab" (bind this to Alt+Tab)
alttab --daemon     Run the daemon in the foreground
alttab --show       Open the GTK4 switcher (one-shot)
alttab --kill       Stop the daemon
alttab --focus-address ADDR   Focus a window by Hyprland address
```

---

## Rust Implementation

### System dependencies

```bash
# Arch Linux
sudo pacman -S gtk4 gtk4-layer-shell rust
```

C libraries required for linking:
- `libgtk-4.so` — GTK 4
- `libgtk4-layer-shell.so` — Wayland layer-shell protocol for GTK4

### Build

```bash
cd rust
cargo build --release
```

The binary is produced at `rust/target/release/alttab`.

### Installation

```bash
sudo cp rust/target/release/alttab /usr/local/bin/alttab
# or into the user PATH
cp rust/target/release/alttab ~/.local/bin/alttab
```

---

## Rust Architecture

```
rust/
├── Cargo.toml
└── src/
    ├── main.rs       — CLI argument dispatch
    ├── ipc.rs        — communication with Hyprland via Unix socket
    ├── daemon.rs     — daemon mode (socket server, spawn-guard)
    ├── theme.rs      — reads colors from mako.ini
    ├── windows.rs    — fetches and sorts Hyprland windows
    └── ui.rs         — GTK4 overlay (visual switcher)
```

### Crates used

| Crate | Version | Role |
|---|---|---|
| `gtk4` | 0.11 | GTK 4 bindings |
| `gtk4-layer-shell` | 0.8 | Wayland layer-shell protocol |
| `gdk4` | 0.11 | GDK 4 bindings (keyboard, display) |
| `gio` | 0.22 | GIO (AppInfo, icons) |
| `gio-unix` | 0.22 | `DesktopAppInfo` (reads `.desktop` files) |
| `glib` | 0.22 | GLib event loop, timers |
| `serde` + `serde_json` | 1 | Deserialization of Hyprland IPC JSON |
| `libc` | 0.2 | `getuid`, `kill`, redirection to `/dev/null` |

### Notable points

**No threads in the UI** — The switcher's socket listener runs via non-blocking polling using `glib::timeout_add_local` (every 16 ms). This avoids `Send` constraints on GTK objects (`Rc<>`, `Cell<>`, local closures).

**State sharing** — All mutable UI state lives in `Rc<Cell<>>` / `Rc<RefCell<>>`. Shared callbacks (`activate`, `cleanup`, `update_sel`) are `Rc<dyn Fn()>` cloned by each event handler.

**Layer-shell via trait** — `gtk4-layer-shell` 0.8 exposes its interface as a trait (`LayerShell`) rather than free functions. Usage: `use gtk4_layer_shell::LayerShell; window.init_layer_shell(); window.set_layer(...);`

**`gio-unix` for icons** — `DesktopAppInfo` was moved out of `gio` in version 0.22. You must import `gio_unix::DesktopAppInfo` separately.

**`load_from_data` for CSS** — `CssProvider::load_from_string` is gated behind `feature = "v4_12"`. We use `load_from_data(&str)`, which is available without any feature flag.

---

## CLI Interface

Identical between both implementations:

```
alttab                      Starts the daemon if needed, sends "tab"
alttab --daemon             Starts the daemon in the background
alttab --show               Shows the GTK4 switcher
alttab --kill               Stops the daemon
alttab --focus-address ADDR Focus a window by Hyprland address
```

### How it works

1. The Hyprland keybind calls `alttab` (with no argument)
2. If the daemon is not running, it is started automatically
3. The daemon receives `"tab"` on its Unix socket
4. If no switcher is open, it spawns one (`--show`)
5. If a switcher is already open, it sends `"next"` to advance the selection
6. Releasing Alt closes the switcher and focuses the selected window

### Runtime files

All under `$XDG_RUNTIME_DIR` (e.g. `/run/user/1000/`):

| File | Role |
|---|---|
| `hypr-alttab.sock` | Daemon socket |
| `hypr-alttab-switcher.sock` | Active switcher socket |
| `hypr-alttab-daemon.pid` | Daemon PID |
| `hypr-alttab-switcher.pid` | Active switcher PID |

### Theme

Colors are read from `~/.config/omarchy/current/theme/mako.ini`:

```ini
background-color=#2c2525
border-color=#f38d70
text-color=#e6d9db
```

The values above are the defaults if the file is missing.

---

## Example Hyprland configuration

```conf
# ~/.config/hypr/hyprland.conf
bind = ALT, Tab, exec, alttab
```
