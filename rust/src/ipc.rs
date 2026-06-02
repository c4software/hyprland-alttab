use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use serde::de::DeserializeOwned;

fn runtime_dir() -> String {
    std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }))
}

fn hypr_socket_path() -> String {
    let sig = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
        .expect("HYPRLAND_INSTANCE_SIGNATURE is not set");
    format!("{}/hypr/{}/.socket.sock", runtime_dir(), sig)
}

pub fn hypr_request(payload: &str) -> Result<String, std::io::Error> {
    let mut stream = UnixStream::connect(hypr_socket_path())?;
    stream.write_all(payload.as_bytes())?;
    stream.shutdown(Shutdown::Write)?;
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf)?;
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

pub fn hypr_request_json<T: DeserializeOwned>(command: &str) -> Result<T, Box<dyn std::error::Error>> {
    let raw = hypr_request(&format!("j/{}", command))?;
    Ok(serde_json::from_str(&raw)?)
}

pub fn hypr_dispatch(command: &str) -> Result<String, std::io::Error> {
    hypr_request(&format!("dispatch {}", command))
}

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

pub fn get_runtime_dir() -> String {
    runtime_dir()
}
