pub struct Theme {
    pub background: String,
    pub border: String,
    pub text: String,
}

pub fn parse_mako_colors() -> Theme {
    let mut background = "#2c2525".to_string();
    let mut border     = "#f38d70".to_string();
    let mut text       = "#e6d9db".to_string();

    let path = dirs_path();
    if let Ok(contents) = std::fs::read_to_string(&path) {
        for line in contents.lines() {
            let line = line.trim();
            if let Some(v) = line.strip_prefix("background-color=") {
                background = v.trim().to_string();
            } else if let Some(v) = line.strip_prefix("border-color=") {
                border = v.trim().to_string();
            } else if let Some(v) = line.strip_prefix("text-color=") {
                text = v.trim().to_string();
            }
        }
    }

    Theme { background, border, text }
}

fn dirs_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    std::path::PathBuf::from(home)
        .join(".config/omarchy/current/theme/mako.ini")
}
