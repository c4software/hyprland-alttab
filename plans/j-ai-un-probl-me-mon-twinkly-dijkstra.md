# Fix: overlay disparaît immédiatement après apparition

## Contexte

L'overlay alt-tab se ferme immédiatement dès qu'il apparaît. La cause est une race condition entre le timer de 150ms et le handshake Wayland pour l'attribution du clavier.

## Cause racine

Dans `rust/src/ui.rs` (lignes 349-374), un timer de 150ms démarre **immédiatement** à la création de la fenêtre. Il ferme l'overlay si :
- `held_keys` est vide (aucun event clavier reçu)
- `kb.modifier_state()` ne contient pas `ALT_MASK`

Avec `KeyboardMode::Exclusive`, l'attribution du clavier nécessite un aller-retour Wayland :
1. Notre surface commit (`window.present()`)
2. Le compositor accorde le clavier
3. Le compositor envoie `wl_keyboard.enter` + `wl_keyboard.modifiers`
4. GDK traite ces events dans la mainloop GLib

Ce round-trip peut dépasser 150ms. Pendant ce délai, `modifier_state()` retourne 0 et `held_keys` est vide → `activate()` se déclenche → fermeture immédiate.

## Fix

Ne pas démarrer le timer immédiatement. Le démarrer (ou fermer) uniquement **après** avoir reçu l'état initial du modifier depuis le compositor via `EventControllerKey::connect_modifiers`.

`connect_modifiers` se déclenche quand GDK reçoit `wl_keyboard.modifiers` — c'est-à-dire après que le keyboard seat soit effectivement accordé. À ce moment, `modifier_state()` est fiable.

### Logique

```
connect_modifiers (1ère fois seulement) :
  - Alt tenu    → démarrer le timer 150ms (comportement actuel)
  - Alt relâché → fermer immédiatement (l'utilisateur a relâché Alt pendant le démarrage GTK)

Timer watchdog (1s) :
  - Si connect_modifiers ne s'est jamais déclenché (bug compositor) → fermer
```

### Changements dans `rust/src/ui.rs`

1. **Ajouter** `let modifiers_received: Rc<Cell<bool>> = Rc::new(Cell::new(false));`

2. **Remplacer** le timer 150ms immédiat (lignes 349-374) par un timer watchdog de 1s :
   ```rust
   let src = glib::timeout_add_local(Duration::from_millis(1000), move || {
       src_cell.set(None);
       // Fallback si connect_modifiers n'a jamais été déclenché
       if !modifiers_received_wdg.get() {
           activate();
       }
       glib::ControlFlow::Break
   });
   no_key_src.set(Some(src));
   ```

3. **Ajouter** `ctrl.connect_modifiers(...)` dans le bloc keyboard controller (après la création de `ctrl`) :
   ```rust
   ctrl.connect_modifiers({
       let modifiers_received = Rc::clone(&modifiers_received);
       let no_key_src = Rc::clone(&no_key_src);
       let held_keys = Rc::clone(&held_keys);
       let activate = Rc::clone(&activate_fn);
       let window2 = window.clone();
       move |_, state| {
           if modifiers_received.get() {
               return glib::Propagation::Proceed;
           }
           modifiers_received.set(true);
           
           // Annuler le watchdog
           if let Some(src) = no_key_src.take() { src.remove(); }
           
           if state.contains(gdk::ModifierType::ALT_MASK) {
               // Alt tenu : démarrer le vrai timer 150ms
               let activate2 = Rc::clone(&activate);
               let held_keys2 = Rc::clone(&held_keys);
               let window3 = window2.clone();
               let src_cell2 = Rc::clone(&no_key_src);
               let src = glib::timeout_add_local(Duration::from_millis(150), move || {
                   src_cell2.set(None);
                   let kb = gtk4::prelude::WidgetExt::display(&window3)
                       .default_seat()
                       .and_then(|s| s.keyboard());
                   let gdk_alt = kb.map_or(false, |kb| {
                       kb.modifier_state().contains(gdk::ModifierType::ALT_MASK)
                   });
                   if held_keys2.borrow().is_empty() && !gdk_alt {
                       activate2();
                   }
                   glib::ControlFlow::Break
               });
               no_key_src.set(Some(src));
           } else if held_keys.borrow().is_empty() {
               // Alt déjà relâché au moment où l'overlay a obtenu le clavier
               activate();
           }
           glib::Propagation::Proceed
       }
   });
   ```

4. Ajouter les imports nécessaires (`modifiers_received` dans la capture du watchdog).

## Fichier concerné

- `rust/src/ui.rs` — uniquement la fonction `build_window()`

## Vérification

1. `cargo build --release` dans `rust/`
2. Lancer le daemon et appuyer Alt+Tab : l'overlay doit rester visible
3. Relâcher Alt : l'overlay doit se fermer et focus la fenêtre sélectionnée
4. Appuyer Alt+Tab très rapidement et relâcher avant que l'overlay apparaisse : l'overlay doit quand même se fermer rapidement (via la branche "Alt déjà relâché" de `connect_modifiers`)
