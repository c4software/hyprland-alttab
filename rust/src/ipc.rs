use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use serde::de::DeserializeOwned;

// ─── Socket helpers ───────────────────────────────────────────────────────────

/// Return `$XDG_RUNTIME_DIR`, falling back to `/run/user/<uid>` when the
/// variable is unset (e.g. when launched from a non-PAM session).
fn runtime_dir() -> String {
    std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }))
}

/// Path to the Hyprland IPC socket for the running instance.
///
/// Hyprland creates one socket per compositor instance under
/// `$XDG_RUNTIME_DIR/hypr/<HYPRLAND_INSTANCE_SIGNATURE>/.socket.sock`.
fn hypr_socket_path() -> String {
    let sig = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
        .expect("HYPRLAND_INSTANCE_SIGNATURE is not set");
    format!("{}/hypr/{}/.socket.sock", runtime_dir(), sig)
}

// ─── Hyprland IPC ─────────────────────────────────────────────────────────────

/// Send a raw IPC command to Hyprland and return the response as a `String`.
///
/// The write end is shut down after sending so Hyprland knows the request is
/// complete and can reply.
pub fn hypr_request(payload: &str) -> Result<String, std::io::Error> {
    let mut stream = UnixStream::connect(hypr_socket_path())?;
    stream.write_all(payload.as_bytes())?;
    stream.shutdown(Shutdown::Write)?;
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf)?;
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

/// Send an IPC command and deserialize the JSON response into `T`.
///
/// Hyprland returns JSON when the command is prefixed with `j/`.
pub fn hypr_request_json<T: DeserializeOwned>(command: &str) -> Result<T, Box<dyn std::error::Error>> {
    let raw = hypr_request(&format!("j/{}", command))?;
    Ok(serde_json::from_str(&raw)?)
}

/// Send a `dispatch` IPC command (key bindings, window focus, workspace switch…).
pub fn hypr_dispatch(command: &str) -> Result<String, std::io::Error> {
    hypr_request(&format!("dispatch {}", command))
}

// ─── Window focus ─────────────────────────────────────────────────────────────

/// Focus a window by its Hyprland address.
///
/// Tries a plain `focuswindow address:` first, then a regex-anchored variant.
/// If both fail (e.g. the window is on a hidden workspace), switches to its
/// workspace first and retries.  Returns `true` if focus was confirmed by
/// Hyprland.
pub fn focus_window_by_address(addr: &str) -> bool {
    let candidates = [
        format!("focuswindow address:{}", addr),
        format!("focuswindow address:^{}$", addr),
    ];

    for cmd in &candidates {
        if let Ok(reply) = hypr_dispatch(cmd) {
            if reply.trim().to_lowercase() == "ok" {
                return true;
            }
        }
    }

    // Fallback: switch to the window's workspace, then retry focuswindow.
    if let Ok(clients) = hypr_request_json::<Vec<serde_json::Value>>("clients") {
        if let Some(target) = clients.iter().find(|c| c["address"].as_str() == Some(addr)) {
            if let Some(ws_id) = target["workspace"]["id"].as_i64() {
                let _ = hypr_dispatch(&format!("workspace {}", ws_id));
                for cmd in &candidates {
                    if let Ok(reply) = hypr_dispatch(cmd) {
                        if reply.trim().to_lowercase() == "ok" {
                            return true;
                        }
                    }
                }
            }
        }
    }

    false
}

/// Spawn `alttab --focus-address <addr>` as a detached child after the
/// switcher GTK process exits.
///
/// GTK's `app.quit()` tears down the GLib main loop before we can call
/// Hyprland IPC, so the focus call is delegated to a new short-lived process
/// that runs outside the GTK lifecycle.
pub fn focus_window_after_exit(addr: &str) {
    let exe = std::env::current_exe()
        .unwrap_or_else(|_| std::path::PathBuf::from("alttab"));
    let _ = std::process::Command::new(&exe)
        .arg("--focus-address")
        .arg(addr)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

/// Public re-export of the runtime directory path (used by `daemon.rs`).
pub fn get_runtime_dir() -> String {
    runtime_dir()
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    // Env-var tests mutate process-global state; serialize them with a mutex.
    use std::sync::Mutex;
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn runtime_dir_uses_xdg_env_var() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var("XDG_RUNTIME_DIR", "/tmp/test-xdg-runtime");
        assert_eq!(super::get_runtime_dir(), "/tmp/test-xdg-runtime");
    }

    #[test]
    fn runtime_dir_fallback_starts_with_run_user() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::remove_var("XDG_RUNTIME_DIR");
        let dir = super::get_runtime_dir();
        assert!(dir.starts_with("/run/user/"), "got: {dir}");
    }
}
