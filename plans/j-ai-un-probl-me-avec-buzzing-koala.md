# Context

Le switcher alt-tab (version Rust) se ferme parfois immédiatement après l'ouverture. Le problème est intermittent, ce qui indique une race condition entre le démarrage du processus GTK et l'octroi du siège clavier exclusif par le compositeur Wayland.

## Cause racine

**Fichier** : `rust/src/ui.rs`, ligne 365

```rust
let gdk_alt = kb.map_or(false, |kb| {
    kb.modifier_state().contains(gdk::ModifierType::ALT_MASK)
});
```

Le timer "no-key" démarre immédiatement à la création de la fenêtre (ligne 358, 150 ms), avant que le compositeur n'ait accordé l'accès exclusif au clavier (`KeyboardMode::Exclusive`). Quand le timer se déclenche :

- `held_keys` est vide — aucun événement clavier n'a encore été reçu par l'overlay
- `kb` peut être `None` (siège clavier pas encore disponible) → `map_or(false, …)` retourne `false`
- Condition `held_keys.is_empty() && !gdk_alt` = `true` → fermeture immédiate

Le mode `Exclusive` garantit que les événements clavier seront livrés, mais il y a une fenêtre de temps (0–150 ms) pendant laquelle le compositeur n'a pas encore transmis le `wl_keyboard::enter` à GDK. Pendant cette fenêtre, `kb.modifier_state()` n'est pas fiable.

## Fix

### Correctif principal — `map_or(false, …)` → `map_or(true, …)` (ligne 365)

Quand le clavier n'est pas encore disponible, supposer qu'Alt **est** tenu → ne pas fermer. Une fois le clavier disponible, la vérification est correcte.

```rust
let gdk_alt = kb.map_or(true, |kb| {
    kb.modifier_state().contains(gdk::ModifierType::ALT_MASK)
});
```

Risque : si le clavier n'est _jamais_ disponible (bug Wayland profond), l'overlay ne se fermera pas via ce timer — mais dans ce cas, `key_released` ne fonctionnerait pas non plus, donc c'est un problème distinct.

### Correctif secondaire — mettre à jour le commentaire du `grab_focus()` (ligne 447–451)

Le commentaire mentionne encore `KeyboardMode::OnDemand` alors que le mode actuel est `Exclusive`. Le mettre à jour pour refléter la réalité.

## Fichier critique

- `rust/src/ui.rs` : une seule ligne à changer (365) + commentaire à mettre à jour (449–451)

## Vérification

1. `cargo build` dans `rust/` — doit compiler sans erreur
2. Lancer le switcher plusieurs fois rapidement (Alt+Tab) pour vérifier qu'il ne se ferme plus prématurément
3. Vérifier que Alt+Tab fonctionne normalement : overlay visible, Tab navigue, relâcher Alt ferme et focus la bonne fenêtre
4. Vérifier que relâcher Alt rapidement (avant les icônes) ferme bien l'overlay
