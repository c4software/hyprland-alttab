/// Colors extracted from the active mako notification theme.
///
/// Defaults are the Omarchy dark-rose palette used when the config file is absent.
pub struct Theme {
    pub background: String,
    pub border: String,
    pub text: String,
}

impl Default for Theme {
    fn default() -> Self {
        Theme {
            background: "#2c2525".to_string(),
            border:     "#f38d70".to_string(),
            text:       "#e6d9db".to_string(),
        }
    }
}

/// Parse a mako.ini-formatted string and return the extracted `Theme`.
///
/// Only the three keys the switcher needs (`background-color`, `border-color`,
/// `text-color`) are read; every other line is silently ignored.  This makes
/// the function tolerant of comments, section headers, and unknown keys.
pub(crate) fn parse_ini_content(content: &str) -> Theme {
    let mut theme = Theme::default();
    for line in content.lines() {
        let line = line.trim();
        if let Some(v) = line.strip_prefix("background-color=") {
            theme.background = v.trim().to_string();
        } else if let Some(v) = line.strip_prefix("border-color=") {
            theme.border = v.trim().to_string();
        } else if let Some(v) = line.strip_prefix("text-color=") {
            theme.text = v.trim().to_string();
        }
    }
    theme
}

/// Read theme colors from `~/.config/omarchy/current/theme/mako.ini`.
///
/// Returns [`Theme::default`] if the file is absent or unreadable so the
/// switcher always has valid colors regardless of the host configuration.
pub fn parse_mako_colors() -> Theme {
    let path = config_path();
    match std::fs::read_to_string(&path) {
        Ok(contents) => parse_ini_content(&contents),
        Err(_) => Theme::default(),
    }
}

fn config_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    std::path::PathBuf::from(home).join(".config/omarchy/current/theme/mako.ini")
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_content_yields_defaults() {
        let t = parse_ini_content("");
        assert_eq!(t.background, "#2c2525");
        assert_eq!(t.border,     "#f38d70");
        assert_eq!(t.text,       "#e6d9db");
    }

    #[test]
    fn parses_all_three_keys() {
        let ini = "background-color=#111111\nborder-color=#222222\ntext-color=#333333\n";
        let t = parse_ini_content(ini);
        assert_eq!(t.background, "#111111");
        assert_eq!(t.border,     "#222222");
        assert_eq!(t.text,       "#333333");
    }

    #[test]
    fn partial_override_preserves_other_defaults() {
        let t = parse_ini_content("border-color=#aabbcc");
        assert_eq!(t.background, "#2c2525", "background should stay default");
        assert_eq!(t.border,     "#aabbcc", "border should be overridden");
        assert_eq!(t.text,       "#e6d9db", "text should stay default");
    }

    #[test]
    fn trims_whitespace_around_value() {
        let t = parse_ini_content("  text-color=  #ffffff  \n");
        assert_eq!(t.text, "#ffffff");
    }

    #[test]
    fn ignores_comments_and_unknown_keys() {
        let ini = "# comment\n[section]\nsome-key=ignored\nborder-color=#deadbe\n";
        let t = parse_ini_content(ini);
        assert_eq!(t.border,     "#deadbe");
        assert_eq!(t.background, "#2c2525", "unrelated default must not change");
    }

    #[test]
    fn last_occurrence_of_key_wins() {
        let ini = "text-color=#aaaaaa\ntext-color=#bbbbbb\n";
        let t = parse_ini_content(ini);
        assert_eq!(t.text, "#bbbbbb");
    }
}
