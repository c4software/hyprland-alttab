use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use crate::ipc::get_runtime_dir;

pub fn socket_path()          -> String { format!("{}/hypr-alttab.sock",         get_runtime_dir()) }
pub fn switcher_socket_path() -> String { format!("{}/hypr-alttab-switcher.sock", get_runtime_dir()) }
pub fn daemon_pidfile()       -> String { format!("{}/hypr-alttab-daemon.pid",    get_runtime_dir()) }
pub fn switcher_pidfile()     -> String { format!("{}/hypr-alttab-switcher.pid",  get_runtime_dir()) }

static SPAWN_GUARD: OnceLock<Mutex<Option<Instant>>> = OnceLock::new();
const SPAWN_GUARD_S: f64 = 0.5;

fn spawn_guard() -> &'static Mutex<Option<Instant>> {
    SPAWN_GUARD.get_or_init(|| Mutex::new(None))
}

fn is_pid_alive(pidfile: &str) -> bool {
    let Ok(contents) = std::fs::read_to_string(pidfile) else { return false; };
    let Ok(pid) = contents.trim().parse::<i32>() else { return false; };
    std::path::Path::new(&format!("/proc/{}/status", pid)).exists()
}

pub fn is_daemon_running()   -> bool { is_pid_alive(&daemon_pidfile()) }
pub fn is_switcher_running() -> bool { is_pid_alive(&switcher_pidfile()) }

pub fn send_to_daemon(msg: &str) -> bool {
    match UnixStream::connect(socket_path()) {
        Ok(mut s) => { let _ = s.write_all(msg.as_bytes()); true }
        Err(_) => false,
    }
}

pub fn try_send_next() -> bool {
    match UnixStream::connect(switcher_socket_path()) {
        Ok(mut s) => { let _ = s.write_all(b"next"); true }
        Err(_) => false,
    }
}

pub fn start_daemon() {
    let exe = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("alttab"));
    let mut env = std::collections::HashMap::new();
    env.extend(std::env::vars());
    let lib = "/usr/lib/libgtk4-layer-shell.so";
    let preload = env.get("LD_PRELOAD").cloned().unwrap_or_default();
    let mut parts: Vec<&str> = preload.split(':').filter(|s| !s.is_empty()).collect();
    if !parts.contains(&lib) {
        parts.insert(0, lib);
    }
    let preload_val = parts.join(":");

    let _ = std::process::Command::new(&exe)
        .arg("--daemon")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .env("LD_PRELOAD", &preload_val)
        .spawn();

    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(50));
        if std::path::Path::new(&socket_path()).exists() {
            return;
        }
    }
}

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

fn spawn_switcher() {
    let exe = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("alttab"));
    let lib = "/usr/lib/libgtk4-layer-shell.so";
    let preload = std::env::var("LD_PRELOAD").unwrap_or_default();
    let mut parts: Vec<&str> = preload.split(':').filter(|s| !s.is_empty()).collect();
    if !parts.contains(&lib) {
        parts.insert(0, lib);
    }
    let preload_val = parts.join(":");
    let _ = std::process::Command::new(&exe)
        .arg("--show")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .env("LD_PRELOAD", &preload_val)
        .spawn();
}

fn handle_message(msg: &str) {
    if msg != "tab" {
        return;
    }

    if is_switcher_running() {
        try_send_next();
        return;
    }

    let guard = spawn_guard();
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

pub fn run_daemon_loop() {
    // redirect stdout/stderr to /dev/null
    unsafe {
        let devnull = libc::open(b"/dev/null\0".as_ptr() as *const libc::c_char, libc::O_WRONLY);
        if devnull >= 0 {
            libc::dup2(devnull, 1);
            libc::dup2(devnull, 2);
            libc::close(devnull);
        }
        // Prevent zombie children: kernel reaps them automatically when SIGCHLD is ignored.
        libc::signal(libc::SIGCHLD, libc::SIG_IGN);
    }

    let pidfile = daemon_pidfile();
    let _ = std::fs::write(&pidfile, format!("{}", std::process::id()));

    let sock_path = socket_path();
    let _ = std::fs::remove_file(&sock_path);

    let listener = match UnixListener::bind(&sock_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("daemon bind error: {}", e);
            return;
        }
    };

    for stream in listener.incoming() {
        match stream {
            Ok(mut conn) => {
                let mut buf = [0u8; 64];
                let n = conn.read(&mut buf).unwrap_or(0);
                let msg = std::str::from_utf8(&buf[..n]).unwrap_or("").trim().to_string();
                drop(conn);
                if msg == "quit" {
                    break;
                }
                std::thread::spawn(move || handle_message(&msg));
            }
            Err(_) => break,
        }
    }

    let _ = std::fs::remove_file(&sock_path);
    let _ = std::fs::remove_file(&pidfile);
    std::process::exit(0);
}
