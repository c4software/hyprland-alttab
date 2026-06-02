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

    // default: ensure daemon is running, then send "tab"
    if !daemon::is_daemon_running() {
        daemon::start_daemon();
    }
    daemon::send_to_daemon("tab");
}
