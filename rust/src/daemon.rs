use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use crate::ipc::get_runtime_dir;

// ─── Socket / PID file paths ──────────────────────────────────────────────────

pub fn socket_path()          -> String { format!("{}/hypr-alttab.sock",          get_runtime_dir()) }
pub fn switcher_socket_path() -> String { format!("{}/hypr-alttab-switcher.sock", get_runtime_dir()) }
pub fn daemon_pidfile()       -> String { format!("{}/hypr-alttab-daemon.pid",    get_runtime_dir()) }
pub fn switcher_pidfile()     -> String { format!("{}/hypr-alttab-switcher.pid",  get_runtime_dir()) }

// ─── Spawn guard ──────────────────────────────────────────────────────────────

/// Prevents the daemon from spawning multiple switcher windows if the user
/// presses Alt+Tab faster than the GTK process can start.
static SPAWN_GUARD: OnceLock<Mutex<Option<Instant>>> = OnceLock::new();
const SPAWN_GUARD_S: f64 = 0.5;

fn spawn_guard() -> &'static Mutex<Option<Instant>> {
    SPAWN_GUARD.get_or_init(|| Mutex::new(None))
}

// ─── Process health ───────────────────────────────────────────────────────────

/// Return `true` if the PID stored in `pidfile` maps to a live `/proc` entry.
///
/// Using `/proc/<pid>/status` rather than `kill(pid, 0)` avoids permission
/// issues when the caller is unprivileged.
pub(crate) fn is_pid_alive(pidfile: &str) -> bool {
    let Ok(contents) = std::fs::read_to_string(pidfile) else { return false; };
    let Ok(pid)      = contents.trim().parse::<i32>() else { return false; };
    std::path::Path::new(&format!("/proc/{}/status", pid)).exists()
}

pub fn is_daemon_running()   -> bool { is_pid_alive(&daemon_pidfile()) }
pub fn is_switcher_running() -> bool { is_pid_alive(&switcher_pidfile()) }

// ─── IPC helpers ─────────────────────────────────────────────────────────────

/// Send `msg` to the daemon socket.  Returns `false` if the daemon is not
/// reachable (socket does not exist or connection refused).
pub fn send_to_daemon(msg: &str) -> bool {
    match UnixStream::connect(socket_path()) {
        Ok(mut s) => { let _ = s.write_all(msg.as_bytes()); true }
        Err(_) => false,
    }
}

/// Send `"next"` to the switcher socket to advance the selection.
pub fn try_send_next() -> bool {
    match UnixStream::connect(switcher_socket_path()) {
        Ok(mut s) => { let _ = s.write_all(b"next"); true }
        Err(_) => false,
    }
}

// ─── Daemon lifecycle ─────────────────────────────────────────────────────────

/// Spawn the daemon process (`alttab --daemon`) and wait up to 2 s for its
/// socket to appear.
///
/// `LD_PRELOAD` is extended with `libgtk4-layer-shell.so` so the daemon's
/// child switcher processes can find the library even when the user's shell
/// does not have it on `LD_LIBRARY_PATH`.
pub fn start_daemon() {
    let exe = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("alttab"));

    let lib      = "/usr/lib/libgtk4-layer-shell.so";
    let preload  = std::env::var("LD_PRELOAD").unwrap_or_default();
    let mut parts: Vec<&str> = preload.split(':').filter(|s| !s.is_empty()).collect();
    if !parts.contains(&lib) { parts.insert(0, lib); }
    let preload_val = parts.join(":");

    let _ = std::process::Command::new(&exe)
        .arg("--daemon")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .env("LD_PRELOAD", &preload_val)
        .spawn();

    // Poll until the daemon socket appears (max 2 s).
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(50));
        if std::path::Path::new(&socket_path()).exists() {
            return;
        }
    }
}

/// Stop the daemon gracefully by sending it `"quit"`.
///
/// Falls back to `SIGTERM` via the PID file if the socket is unreachable.
pub fn kill_daemon() {
    if send_to_daemon("quit") {
        for _ in 0..20 {
            std::thread::sleep(Duration::from_millis(50));
            if !std::path::Path::new(&socket_path()).exists() {
                return;
            }
        }
    } else {
        let pidfile = daemon_pidfile();
        if let Ok(contents) = std::fs::read_to_string(&pidfile) {
            if let Ok(pid) = contents.trim().parse::<i32>() {
                unsafe { libc::kill(pid, libc::SIGTERM); }
            }
        }
        let _ = std::fs::remove_file(&pidfile);
    }
}

// ─── Switcher spawn ───────────────────────────────────────────────────────────

/// Spawn `alttab --show` as a detached child process.
fn spawn_switcher() {
    let exe = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("alttab"));

    let lib      = "/usr/lib/libgtk4-layer-shell.so";
    let preload  = std::env::var("LD_PRELOAD").unwrap_or_default();
    let mut parts: Vec<&str> = preload.split(':').filter(|s| !s.is_empty()).collect();
    if !parts.contains(&lib) { parts.insert(0, lib); }
    let preload_val = parts.join(":");

    let _ = std::process::Command::new(&exe)
        .arg("--show")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .env("LD_PRELOAD", &preload_val)
        .spawn();
}

/// Handle an incoming daemon message.
///
/// `"tab"` is the only recognized command:
/// - if the switcher is already open, advance its selection via `"next"`;
/// - otherwise, spawn a new switcher (subject to the spawn guard).
fn handle_message(msg: &str) {
    if msg != "tab" {
        return;
    }

    if is_switcher_running() {
        try_send_next();
        return;
    }

    // Spawn guard: ignore bursts of "tab" within 500 ms to avoid racing
    // between pidfile creation and the next is_switcher_running() check.
    let guard    = spawn_guard();
    let mut lock = guard.lock().unwrap();
    if let Some(ts) = *lock {
        if ts.elapsed().as_secs_f64() < SPAWN_GUARD_S {
            return;
        }
    }
    *lock = Some(Instant::now());
    drop(lock);

    spawn_switcher();
}

// ─── Daemon main loop ─────────────────────────────────────────────────────────

/// Entry point for `alttab --daemon`.
///
/// Sets up the daemon environment and blocks on the Unix socket accepting
/// messages until `"quit"` is received.
///
/// Notable setup steps:
/// - stdout/stderr redirected to `/dev/null` (daemon has no terminal).
/// - `SIGCHLD` set to `SIG_IGN` so the kernel automatically reaps switcher
///   child processes; without this they would remain as zombies until the
///   daemon exits.
pub fn run_daemon_loop() {
    unsafe {
        // Redirect stdout/stderr so stray GTK warnings don't litter the terminal.
        let devnull = libc::open(b"/dev/null\0".as_ptr() as *const libc::c_char, libc::O_WRONLY);
        if devnull >= 0 {
            libc::dup2(devnull, 1);
            libc::dup2(devnull, 2);
            libc::close(devnull);
        }
        // Prevent zombie children: when SIGCHLD is ignored the kernel reaps
        // terminated children automatically (POSIX.1-2001 §SA_NOCLDWAIT).
        libc::signal(libc::SIGCHLD, libc::SIG_IGN);
    }

    let pidfile = daemon_pidfile();
    let _ = std::fs::write(&pidfile, format!("{}", std::process::id()));

    let sock_path = socket_path();
    let _ = std::fs::remove_file(&sock_path);

    let listener = match UnixListener::bind(&sock_path) {
        Ok(l)  => l,
        Err(e) => { eprintln!("daemon bind error: {}", e); return; }
    };

    for stream in listener.incoming() {
        match stream {
            Ok(mut conn) => {
                let mut buf = [0u8; 64];
                let n   = conn.read(&mut buf).unwrap_or(0);
                let msg = std::str::from_utf8(&buf[..n]).unwrap_or("").trim().to_string();
                drop(conn);
                if msg == "quit" { break; }
                // Handle in a thread so a slow switcher spawn doesn't block
                // the next incoming "tab".
                std::thread::spawn(move || handle_message(&msg));
            }
            Err(_) => break,
        }
    }

    let _ = std::fs::remove_file(&sock_path);
    let _ = std::fs::remove_file(&pidfile);
    std::process::exit(0);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Write `contents` to a temp file, run the check, then clean up.
    fn with_pidfile(contents: &str, f: impl FnOnce(&str) -> bool) -> bool {
        let path = format!("/tmp/alttab-test-{}.pid", std::process::id());
        std::fs::write(&path, contents).unwrap();
        let result = f(&path);
        let _ = std::fs::remove_file(&path);
        result
    }

    #[test]
    fn current_process_is_alive() {
        let pid = std::process::id().to_string();
        assert!(with_pidfile(&pid, |p| is_pid_alive(p)));
    }

    #[test]
    fn nonexistent_pid_is_not_alive() {
        // PID 99999999 is virtually guaranteed not to exist.
        assert!(!with_pidfile("99999999", |p| is_pid_alive(p)));
    }

    #[test]
    fn missing_pidfile_is_not_alive() {
        assert!(!is_pid_alive("/tmp/alttab-this-file-does-not-exist-XYZ.pid"));
    }

    #[test]
    fn malformed_pidfile_is_not_alive() {
        assert!(!with_pidfile("not-a-number", |p| is_pid_alive(p)));
    }
}
