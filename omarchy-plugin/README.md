# hyprland-alttab — plugin Omarchy shell

Switcher Alt+Tab en QML, hébergé comme plugin `service` dans le process
`omarchy-shell` (Quickshell) : un seul process persistant, pas de daemon,
pas de socket, pas d'autostart à gérer.

## Prérequis

- Omarchy avec le shell Quickshell (`omarchy-shell`)
- Hyprland ≥ 0.56 (config Lua)

## Installation

> Le `manifest.json` vit à la racine du dépôt (exigence d'`omarchy plugin add`),
> avec `entryPoints` pointant vers `omarchy-plugin/Service.qml`.

1. Installer et activer :

```sh
omarchy plugin add https://github.com/c4software/hyprland-alttab --enable
```

En développement local, lier une copie de travail à la place :

```sh
ln -sfn ~/projets/hyprland-alttab ~/.config/omarchy/plugins/vbrosseau.alttab
omarchy plugin enable vbrosseau.alttab
```

2. Bindings — dans `~/.config/hypr/customisation.lua` (ou `bindings.lua`) :

```lua
hl.unbind("ALT + TAB")
o.bind("ALT + TAB", nil, hl.dsp.global("omarchy-alttab:next"), { repeating = true })
hl.unbind("SUPER + TAB")
o.bind("SUPER + TAB", nil, hl.dsp.global("omarchy-alttab:next"), { repeating = true })
hl.layer_rule({ match = { namespace = "omarchy-alttab" }, no_anim = true })
```

3. `omarchy restart shell`, puis `hyprctl reload` et vérifier avec
   `hyprctl configerrors`. Le shortcut doit apparaître dans
   `hyprctl globalshortcuts`.

Les modifications du code du plugin rechargent automatiquement
(`omarchy-shell shell rescanPlugins` pour forcer).

## Test manuel

```sh
hyprctl dispatch 'hl.dsp.global("omarchy-alttab:next")'   # ouvre l'overlay
```

## Comportement

- ALT+Tab / SUPER+Tab : ouvre l'overlay, ré-appui avance la sélection.
- Tab/Droite → suivant, Shift+Tab/Gauche → précédent, Entrée → activer,
  Échap → fermer sans focus, relâcher ALT/SUPER → activer.
- L'overlay reste ouvert tant qu'ALT ou SUPER est physiquement enfoncé
  (vérifié via `hl.is_key_down` quand aucun événement clavier ne parvient
  à l'overlay — cas du Tab relâché avant l'obtention du clavier).
- Souris : survol sélectionne, clic active, pointeur sorti de l'overlay +
  relâchement → fermeture sans changement de focus.
- Fenêtres groupées par workspace (actif en premier), triées par récence
  (focusHistoryID), fenêtres pinned exclues.
- Couleurs : singleton `Color` du shell (`qs.Commons`) — suit le thème
  Omarchy automatiquement.
