# Plan — Fix: overlay reste visible après relâchement Alt + sortie souris

## Context

Quand l'utilisateur maintient Alt, utilise la souris, puis relâche Alt et sort le pointeur de l'overlay, la fenêtre ne disparaît pas.

**Cause racine :** L'overlay utilise `KeyboardMode::OnDemand` et appelle `grab_focus()` au démarrage. Mais si l'utilisateur clique à l'extérieur de la surface layer-shell (ou interagit avec la souris d'une façon qui transfère le focus clavier), le compositeur Wayland donne le focus clavier à l'autre fenêtre. À partir de ce moment, l'événement `key_released` pour Alt n'est plus livré à l'overlay. Le timer one-shot de 150ms (no-key timer) a déjà tiré depuis longtemps, et rien d'autre ne peut déclencher `activate_fn()`. L'overlay reste bloqué indéfiniment.

## Fichier à modifier

- `rust/src/ui.rs` — fonction `build_window()`

## Changements

### 1. Nouveau flag `closed` (double-call guard)

Ajouter dans la section "Shared state" (ligne ~142) :
```rust
let closed: Rc<Cell<bool>> = Rc::new(Cell::new(false));
```

Modifier `activate_fn` pour retourner immédiatement si déjà appelé :
```rust
let activate_fn: Rc<dyn Fn()> = Rc::new({
    let closed = Rc::clone(&closed);
    // ... autres captures existantes ...
    move || {
        if closed.get() { return; }
        closed.set(true);
        window.set_visible(false);
        // ... reste du code existant inchangé ...
    }
});
```

Ce guard est nécessaire car le timer récurrent (ci-dessous) peut tirer en même temps que le `key_released`, ce qui appellerait `activate_fn` deux fois et déclencherait `focus_window_after_exit` en double.

### 2. Nouveau `poll_src` dans l'état partagé

Ajouter avec les autres sources (ligne ~146) :
```rust
let poll_src: Rc<Cell<Option<glib::SourceId>>> = Rc::new(Cell::new(None));
```

### 3. Modifier `cleanup_fn` pour annuler `poll_src`

```rust
let cleanup_fn: Rc<dyn Fn()> = Rc::new({
    let no_key_src = Rc::clone(&no_key_src);
    let socket_src = Rc::clone(&socket_src);
    let poll_src   = Rc::clone(&poll_src);   // ← ajouter
    move || {
        if let Some(src) = no_key_src.take() { src.remove(); }
        if let Some(src) = socket_src.take() { src.remove(); }
        if let Some(src) = poll_src.take()   { src.remove(); }  // ← ajouter
        let _ = std::fs::remove_file(switcher_socket_path());
        let _ = std::fs::remove_file(switcher_pidfile());
    }
});
```

### 4. Ajouter le timer récurrent de vérification Alt (après la section no-key timer)

Placer après le bloc "No-key timer" (ligne ~374), avant le "Keyboard controller" :

```rust
// ── Alt-state poll timer ──────────────────────────────────────────────
// Handles the case where keyboard focus left the overlay (e.g. mouse
// clicked outside), so key_released is never delivered. Checks GDK
// modifier state every 200 ms and closes if Alt is no longer held.
{
    let activate = Rc::clone(&activate_fn);
    let window3  = window.clone();
    let src = glib::timeout_add_local(Duration::from_millis(200), move || {
        let kb = gtk4::prelude::WidgetExt::display(&window3)
            .default_seat()
            .and_then(|s| s.keyboard());
        let gdk_alt = kb.map_or(false, |kb| {
            kb.modifier_state().contains(gdk::ModifierType::ALT_MASK)
        });
        if !gdk_alt {
            activate();
            return glib::ControlFlow::Break;
        }
        glib::ControlFlow::Continue
    });
    poll_src.set(Some(src));
}
```

## Ordering des déclarations

`poll_src` doit être déclaré **avant** `cleanup_fn` (car `cleanup_fn` le capture). `closed` doit être déclaré **avant** `activate_fn`. L'ordre final dans la section "Shared state" :

```
selected, held_keys, no_key_src, socket_src, poll_src, closed, frames, windows_rc, mouse_inside
```

## Vérification

1. `cargo build` dans `rust/`
2. Lancer le daemon : `./target/debug/alttab --daemon &`
3. **Cas nominal** : Alt+Tab, relâcher Alt → overlay disparaît ✓
4. **Cas bug** : Alt+Tab, cliquer à l'extérieur de l'overlay (perd le focus clavier), relâcher Alt, bouger la souris → overlay doit disparaître dans ≤200 ms ✓
5. **Cas escape** : Alt+Tab, appuyer Escape → overlay disparaît sans changer de fenêtre ✓
6. **Cas click icône** : Alt+Tab, cliquer une icône → fenêtre activée ✓
