# Plan : icônes des applications web Chrome manquantes

## Contexte

Les applications web lancées via `omarchy-launch-webapp` (Discord, ChatGPT, WhatsApp, etc.) ne montrent pas leur icône dans le switcher.

Hyprland rapporte la `class` de ces fenêtres au format Chrome PWA :
```
chrome-discord.com__channels_@me-Default
```
…et non le nom de l'app (`Discord`). Le titre, lui, est `"(3) Discord | @DHH"`.

Les fichiers `.desktop` correspondants :
- n'ont **pas** de champ `StartupWMClass` → la recherche par `StartupWMClass` (étape 2) ne trouve rien
- ont un `Icon` avec **chemin absolu** vers un PNG local (`~/.local/share/applications/icons/Discord.png`)

## Diagnostic du flux d'échec

Pour une fenêtre Discord (`class = "chrome-discord.com__channels_@me-Default"`, `title = "(3) Discord | @DHH"`) :
1. Lookup `.desktop` par nom → `chrome-discord.com__channels_@me-Default.desktop` n'existe pas → échec
2. Scan `StartupWMClass` → aucun `.desktop` de webapp n'a ce champ → non trouvé
3. Icon theme → pas d'icône `chrome-discord.com__channels_@me-Default` → icône générique

## Solution

Modifier `make_icon_widget` dans `rust/src/ui.rs` pour accepter aussi le **titre** de la fenêtre, et ajouter une **étape 2.5** : scan des `.desktop` par correspondance `Name` ↔ titre.

- Après l'échec du scan `StartupWMClass`, itérer sur tous les `DesktopAppInfo`
- Vérifier si `app.name()` (champ `Name=`, insensible à la casse) apparaît dans le titre de la fenêtre
- Si match → utiliser l'icône de ce `.desktop`

Exemple : `Name="Discord"` → `"discord"` est dans `"(3) discord | @dhh"` → match → icône Discord.png utilisée.

Cette approche est générale : elle fonctionne pour toutes les apps web, sans toucher aux fichiers `.desktop`.

## Fichiers à modifier

### `rust/src/ui.rs`

**Signature** :
```rust
// Avant
fn make_icon_widget(cls: &str) -> Image

// Après
fn make_icon_widget(cls: &str, title: &str) -> Image
```

**Nouveau bloc à insérer** après la boucle `StartupWMClass` (~ligne 74), avant la recherche dans le thème d'icônes :

```rust
// 2.5. Scan all .desktop files for a Name match against the window title.
//      Chrome --app=URL web apps have a WM_CLASS like
//      "chrome-discord.com__channels_@me-Default", but their title contains
//      the app name (e.g. "Discord"). Match Name= against the title as fallback.
let title_lower = title.to_lowercase();
if !title_lower.is_empty() {
    for app_info in gio::AppInfo::all() {
        if let Ok(dapp) = app_info.dynamic_cast::<gio_unix::DesktopAppInfo>() {
            let name = dapp.name().to_lowercase();
            if !name.is_empty() && title_lower.contains(&*name) {
                if let Some(icon) = gio::prelude::AppInfoExt::icon(&dapp) {
                    img.set_from_gicon(&icon);
                    return img;
                }
            }
        }
    }
}
```

**Site d'appel** (~ligne 267) — passer `_title` au lieu de l'ignorer :
```rust
// Avant
frame.append(&make_icon_widget(cls));

// Après
frame.append(&make_icon_widget(cls, _title));
```

Et renommer `_title` en `title` dans le pattern de déstructuration à la ligne ~260 :
```rust
for (cls, title, _addr, hidden, _fhid) in entries {
```

## Vérification

1. `cargo build` dans `rust/`
2. Ouvrir le switcher avec Discord (Chrome web app) en cours
3. Vérifier que l'icône Discord apparaît au lieu de l'icône générique
4. Vérifier que les autres apps (Slack natif, Signal, JetBrains) ne régressent pas
