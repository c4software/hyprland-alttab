# Plan : Ajouter la touche SUPER comme modificateur de maintien

## Context

Actuellement, le switcher Alt+Tab ne reconnaît que les touches `Alt_L`/`Alt_R` comme modificateur de maintien. L'objectif est que `Super+Tab` fonctionne aussi : l'overlay reste ouvert tant que SUPER (touche Windows/Meta) est maintenu, exactement comme ALT.

Les deux implémentations (Rust et Python) partagent la même logique : quand toutes les touches non-modificatrices sont relâchées ET que Alt n'est plus enfoncé → activer la fenêtre. Il faut étendre cette condition pour inclure SUPER.

## Changements

### Rust — `rust/src/ui.rs`

Trois endroits à modifier, tous liés au même invariant :

**1. Timer de secours (no-key timer) — lignes 368-370**
```rust
// Avant
let gdk_alt = kb.map_or(true, |kb| {
    kb.modifier_state().contains(gdk::ModifierType::ALT_MASK)
});
if held_keys.borrow().is_empty() && !gdk_alt {

// Après
let modifier_held = kb.map_or(true, |kb| {
    let mods = kb.modifier_state();
    mods.contains(gdk::ModifierType::ALT_MASK)
        || mods.contains(gdk::ModifierType::SUPER_MASK)
});
if held_keys.borrow().is_empty() && !modifier_held {
```

**2. Handler `connect_key_released` — lignes 427-430**
```rust
// Avant
let alt_releasing = keyval == gdk::Key::Alt_L || keyval == gdk::Key::Alt_R;
let alt_held = state.contains(gdk::ModifierType::ALT_MASK) && !alt_releasing;
if held2.borrow().is_empty() && !alt_held {

// Après
let alt_releasing   = keyval == gdk::Key::Alt_L   || keyval == gdk::Key::Alt_R;
let super_releasing = keyval == gdk::Key::Super_L  || keyval == gdk::Key::Super_R;
let alt_held   = state.contains(gdk::ModifierType::ALT_MASK)   && !alt_releasing;
let super_held = state.contains(gdk::ModifierType::SUPER_MASK) && !super_releasing;
if held2.borrow().is_empty() && !alt_held && !super_held {
```

### Python — `python/alttab`

Trois endroits symétriques :

**1. `_on_no_key_timeout` — ligne 421**
```python
# Avant
gdk_alt = bool(kb.get_modifier_state() & Gdk.ModifierType.ALT_MASK) if kb else False
if not self._held_keys and not gdk_alt:

# Après
mods = kb.get_modifier_state() if kb else 0
modifier_held = bool(mods & (Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK))
if not self._held_keys and not modifier_held:
```

**2. `on_key_release` — lignes 573-576**
```python
# Avant
alt_releasing = keyval in (Gdk.KEY_Alt_L, Gdk.KEY_Alt_R)
alt_still_held = bool(state & Gdk.ModifierType.ALT_MASK) and not alt_releasing
if not self._held_keys and not alt_still_held:

# Après
alt_releasing   = keyval in (Gdk.KEY_Alt_L,   Gdk.KEY_Alt_R)
super_releasing = keyval in (Gdk.KEY_Super_L,  Gdk.KEY_Super_R)
alt_still_held   = bool(state & Gdk.ModifierType.ALT_MASK)   and not alt_releasing
super_still_held = bool(state & Gdk.ModifierType.SUPER_MASK) and not super_releasing
if not self._held_keys and not alt_still_held and not super_still_held:
```

## Note sur la configuration Hyprland

Le daemon n'a pas besoin de modification. Il faut ajouter le binding dans la config Hyprland :

```
bind = SUPER, Tab, exec, alttab
```

### Capture des touches par-dessus les bindings Hyprland

**`KeyboardMode::Exclusive` (ui.rs:165) gère déjà ça.** Quand le switcher s'ouvre, Hyprland cède l'intégralité du clavier à la surface layer-shell (layer Overlay). Tous les bindings Hyprland sont suspendus pendant la durée de vie du switcher — c'est pourquoi Alt+Tab ne re-spawne pas un nouveau switcher quand on appuie sur Tab pour naviguer.

Même comportement avec Super+Tab :
1. 1er appui `Super+Tab` → Hyprland binding → daemon → switcher s'ouvre avec exclusive mode
2. Tab suivants (Super maintenu) → GTK exclusive capture tout → `key_pressed` handler navigue
3. Super relâché → notre `key_released` handler détecte `SUPER_MASK` absent → active la fenêtre

Aucun code supplémentaire n'est nécessaire pour l'interception des touches.

## Vérification

1. `cargo build` dans `rust/` — doit compiler sans erreur
2. Tester `Alt+Tab` : comportement inchangé
3. Configurer `Super+Tab` dans Hyprland, tester : l'overlay reste ouvert tant que Super est maintenu, se ferme à son relâchement
4. Tester `Super+Tab`, relâcher Super avant d'avoir sélectionné → fenêtre initiale reste active (Escape behavior)
