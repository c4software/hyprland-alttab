//! # hyprland-alttab
//!
//! Alt+Tab window switcher for Hyprland using a GTK4 layer-shell overlay.
//!
//! ## Architecture
//!
//! ```text
//! alttab (default)
//!   └─ starts daemon if needed, then sends "tab"
//!
//! alttab --daemon          long-lived socket server, spawns --show on demand
//! alttab --show            one-shot GTK4 overlay (runs until Alt is released)
//! alttab --focus-address   called by the overlay after GTK quits to focus a window
//! alttab --kill            graceful daemon shutdown
//! ```
//!
//! The focus call is split into a separate `--focus-address` invocation because
//! `app.quit()` tears down the GLib event loop before any post-quit Hyprland IPC
//! could run inside the same process.

extern crate gio_unix;
mod daemon;
mod ipc;
mod theme;
mod ui;
mod windows;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.contains(&"--daemon".to_string()) {
        daemon::run_daemon_loop();
        return;
    }

    if let Some(pos) = args.iter().position(|a| a == "--focus-address") {
        let addr = args.get(pos + 1).cloned().unwrap_or_default();
        if addr.is_empty() {
            std::process::exit(1);
        }
        ipc::focus_window_by_address(&addr);
        return;
    }

    if args.contains(&"--kill".to_string()) {
        daemon::kill_daemon();
        return;
    }

    if args.contains(&"--show".to_string()) {
        ui::run_switcher();
        return;
    }

    // Default: ensure daemon is running, then signal it to open/advance the switcher.
    if !daemon::is_daemon_running() {
        daemon::start_daemon();
    }
    daemon::send_to_daemon("tab");
}
