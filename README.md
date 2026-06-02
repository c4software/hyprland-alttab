# hyprland-alttab

Switcher de fenêtres Alt+Tab pour Hyprland, avec overlay GTK4 layer-shell.  
Disponible en deux implémentations identiques : Python (original) et Rust.

---

## Implémentation Rust

### Dépendances système

```bash
# Arch Linux
sudo pacman -S gtk4 gtk4-layer-shell rust
```

Les bibliothèques C nécessaires au link :
- `libgtk-4.so` — GTK 4
- `libgtk4-layer-shell.so` — protocole Wayland layer-shell pour GTK4

### Build

```bash
cd rust
cargo build --release
```

Le binaire est généré dans `rust/target/release/alttab`.

### Installation

```bash
sudo cp rust/target/release/alttab /usr/local/bin/alttab
# ou dans le PATH utilisateur
cp rust/target/release/alttab ~/.local/bin/alttab
```

---

## Architecture Rust

```
rust/
├── Cargo.toml
└── src/
    ├── main.rs       — dispatch des arguments CLI
    ├── ipc.rs        — communication avec Hyprland via socket Unix
    ├── daemon.rs     — mode daemon (serveur socket, spawn-guard)
    ├── theme.rs      — lecture des couleurs depuis mako.ini
    ├── windows.rs    — récupération et tri des fenêtres Hyprland
    └── ui.rs         — overlay GTK4 (switcher visuel)
```

### Crates utilisées

| Crate | Version | Rôle |
|---|---|---|
| `gtk4` | 0.11 | Bindings GTK 4 |
| `gtk4-layer-shell` | 0.8 | Protocole Wayland layer-shell |
| `gdk4` | 0.11 | Bindings GDK 4 (clavier, display) |
| `gio` | 0.22 | GIO (AppInfo, icônes) |
| `gio-unix` | 0.22 | `DesktopAppInfo` (lecture des `.desktop`) |
| `glib` | 0.22 | Boucle d'événements GLib, timers |
| `serde` + `serde_json` | 1 | Désérialisation du JSON Hyprland IPC |
| `libc` | 0.2 | `getuid`, `kill`, redirection vers `/dev/null` |

### Points notables

**Pas de threads dans l'UI** — Le listener socket du switcher tourne en polling non-bloquant via `glib::timeout_add_local` (toutes les 16 ms). Cela évite les contraintes `Send` sur les objets GTK (`Rc<>`, `Cell<>`, closures locales).

**Partage d'état** — Tout l'état mutable de l'UI est dans des `Rc<Cell<>>` / `Rc<RefCell<>>`. Les callbacks partagés (`activate`, `cleanup`, `update_sel`) sont des `Rc<dyn Fn()>` clonés par chaque gestionnaire d'événement.

**Layer-shell via trait** — `gtk4-layer-shell` 0.8 expose une interface en trait (`LayerShell`) plutôt qu'en fonctions libres. Utilisation : `use gtk4_layer_shell::LayerShell; window.init_layer_shell(); window.set_layer(...);`

**`gio-unix` pour les icônes** — `DesktopAppInfo` a été déplacé hors de `gio` dans la version 0.22. Il faut importer `gio_unix::DesktopAppInfo` séparément.

**`load_from_data` pour le CSS** — `CssProvider::load_from_string` est gated derrière `feature = "v4_12"`. On utilise `load_from_data(&str)` qui est disponible sans feature flag.

---

## Interface CLI

Identique entre les deux implémentations :

```
alttab                      Lance le daemon si besoin, envoie "tab"
alttab --daemon             Démarre le daemon en arrière-plan
alttab --show               Affiche le switcher GTK4
alttab --kill               Arrête le daemon
alttab --focus-address ADDR Focus une fenêtre par adresse Hyprland
```

### Fonctionnement

1. Le keybind Hyprland appelle `alttab` (sans argument)
2. Si le daemon n'est pas lancé, il est démarré automatiquement
3. Le daemon reçoit `"tab"` sur son socket Unix
4. S'il n'y a pas de switcher ouvert, il le spawn (`--show`)
5. Si le switcher est déjà ouvert, il lui envoie `"next"` pour avancer la sélection
6. Relâcher Alt ferme le switcher et focus la fenêtre sélectionnée

### Fichiers runtime

Tous dans `$XDG_RUNTIME_DIR` (ex: `/run/user/1000/`) :

| Fichier | Rôle |
|---|---|
| `hypr-alttab.sock` | Socket du daemon |
| `hypr-alttab-switcher.sock` | Socket du switcher actif |
| `hypr-alttab-daemon.pid` | PID du daemon |
| `hypr-alttab-switcher.pid` | PID du switcher actif |

### Thème

Les couleurs sont lues depuis `~/.config/omarchy/current/theme/mako.ini` :

```ini
background-color=#2c2525
border-color=#f38d70
text-color=#e6d9db
```

Les valeurs ci-dessus sont les défauts si le fichier est absent.

---

## Exemple de configuration Hyprland

```conf
# ~/.config/hypr/hyprland.conf
bind = ALT, Tab, exec, alttab
```
