/// Colors extracted from the active Omarchy theme.
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

/// Parse a colors.toml-formatted string and return the extracted `Theme`.
/// Only `background`, `accent` and `foreground` are read.
pub(crate) fn parse_toml_content(content: &str) -> Theme {
    let mut theme = Theme::default();
    for line in content.lines() {
        let Some((key, value)) = line.split_once('=') else { continue; };
        let value = value.trim().trim_matches('"');
        if value.is_empty() { continue; }
        match key.trim() {
            "background" => theme.background = value.to_string(),
            "accent"     => theme.border     = value.to_string(),
            "foreground" => theme.text       = value.to_string(),
            _ => {}
        }
    }
    theme
}

/// Read theme colors from `~/.local/state/omarchy/current/theme/colors.toml`.
/// Returns [`Theme::default`] if the file is absent or unreadable.
pub fn load_theme_colors() -> Theme {
    match std::fs::read_to_string(config_path()) {
        Ok(contents) => parse_toml_content(&contents),
        Err(_) => Theme::default(),
    }
}

fn config_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    std::path::PathBuf::from(home).join(".local/state/omarchy/current/theme/colors.toml")
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_content_yields_defaults() {
        let t = parse_toml_content("");
        assert_eq!(t.background, "#2c2525");
        assert_eq!(t.border,     "#f38d70");
        assert_eq!(t.text,       "#e6d9db");
    }

    #[test]
    fn parses_all_three_keys() {
        let toml = "background = \"#282828\"\naccent = \"#7daea3\"\nforeground = \"#d4be98\"\n";
        let t = parse_toml_content(toml);
        assert_eq!(t.background, "#282828");
        assert_eq!(t.border,     "#7daea3");
        assert_eq!(t.text,       "#d4be98");
    }

    #[test]
    fn partial_override_preserves_other_defaults() {
        let t = parse_toml_content("accent = \"#aabbcc\"");
        assert_eq!(t.background, "#2c2525", "background should stay default");
        assert_eq!(t.border,     "#aabbcc", "border should be overridden");
        assert_eq!(t.text,       "#e6d9db", "text should stay default");
    }

    #[test]
    fn ignores_comments_and_unknown_keys() {
        let toml = "# comment\nmode = \"dark\"\nbright_red = \"#ea6962\"\naccent = \"#deadbe\"\n";
        let t = parse_toml_content(toml);
        assert_eq!(t.border,     "#deadbe");
        assert_eq!(t.background, "#2c2525", "unrelated default must not change");
    }

    #[test]
    fn last_occurrence_of_key_wins() {
        let toml = "foreground = \"#aaaaaa\"\nforeground = \"#bbbbbb\"\n";
        let t = parse_toml_content(toml);
        assert_eq!(t.text, "#bbbbbb");
    }

    #[test]
    fn unquoted_values_are_accepted() {
        let t = parse_toml_content("background = #111111");
        assert_eq!(t.background, "#111111");
    }
}
