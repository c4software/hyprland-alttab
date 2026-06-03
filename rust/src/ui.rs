//! GTK4 layer-shell overlay for the Alt+Tab switcher.
//!
//! ## Threading model
//!
//! GTK objects are `!Send`, so no threads are used inside this module.
//! Shared mutable state lives in `Rc<Cell<>>` / `Rc<RefCell<>>`.
//! Shared callbacks are `Rc<dyn Fn()>` cloned into each event handler.
//!
//! The daemon socket is polled every 16 ms via `glib::timeout_add_local` on a
//! non-blocking `UnixListener` instead of a background thread, keeping all GTK
//! access on the main thread.

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::io::Read;
use std::os::unix::net::UnixListener;
use std::rc::Rc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::{
    gdk, gio, glib, Application, ApplicationWindow, Box as GtkBox, CssProvider,
    EventControllerKey, EventControllerMotion, GestureClick, Image, Label, Orientation, Separator,
};
use gtk4_layer_shell::LayerShell;

use crate::daemon::{switcher_pidfile, switcher_socket_path};
use crate::ipc::focus_window_after_exit;
use crate::theme::parse_mako_colors;
use crate::windows::{flat_windows, get_windows, WindowEntry};

// ─── Icon resolution ──────────────────────────────────────────────────────────

/// Build an `Image` widget for a window's application class.
///
/// Resolution order:
/// 1. `gio_unix::DesktopAppInfo` — looks up `<class>.desktop` under several
///    case / dash / dot-part variants and returns the app's declared icon.
/// 2. GTK icon theme search — tries the same name variants directly.
/// 3. Generic `application-x-executable` fallback.
fn make_icon_widget(cls: &str, title: &str) -> Image {
    let img = Image::new();
    img.set_pixel_size(64);

    let cls_lower = cls.to_lowercase();
    let no_dash   = cls.replace('-', "");
    let dot_part  = cls.split('.').next().unwrap_or(cls);

    // 1. Try direct .desktop lookup by common name patterns (class, lowercase, no-dash, dot-prefix).
    for candidate in &[cls, cls_lower.as_str(), no_dash.as_str(), dot_part] {
        if candidate.is_empty() { continue; }
        if let Some(app) = gio_unix::DesktopAppInfo::new(&format!("{}.desktop", candidate)) {
            if let Some(icon) = gio::prelude::AppInfoExt::icon(&app) {
                img.set_from_gicon(&icon);
                return img;
            }
        }
    }

    // 2. Scan all .desktop files for a StartupWMClass match.
    //    JetBrains Toolbox appends a UUID to the .desktop filename
    //    (e.g. jetbrains-webstorm-3cb3f5ef-….desktop) so the name-based
    //    lookup above never finds it.  StartupWMClass is the authoritative
    //    field that maps a window class to its .desktop entry.
    for app_info in gio::AppInfo::all() {
        if let Ok(dapp) = app_info.dynamic_cast::<gio_unix::DesktopAppInfo>() {
            if dapp.startup_wm_class().map(|s| s.to_lowercase() == cls_lower).unwrap_or(false) {
                if let Some(icon) = gio::prelude::AppInfoExt::icon(&dapp) {
                    img.set_from_gicon(&icon);
                    return img;
                }
            }
        }
    }

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

    // 3. Fall back to searching the icon theme by name.
    if let Some(display) = gdk::Display::default() {
        let theme = gtk4::IconTheme::for_display(&display);
        for name in &[
            cls,
            cls_lower.as_str(),
            cls.split('-').next().unwrap_or(cls),
            cls.split('.').last().unwrap_or(cls),
        ] {
            if !name.is_empty() && theme.has_icon(name) {
                img.set_icon_name(Some(name));
                return img;
            }
        }
    }

    img.set_icon_name(Some("application-x-executable"));
    img
}

// ─── Window builder ───────────────────────────────────────────────────────────

/// Build and show the switcher overlay.
///
/// The window is a layer-shell `Overlay` surface that:
/// - does **not** steal focus on map (`KeyboardMode::OnDemand`);
/// - explicitly grabs keyboard focus after `present()` so key events work
///   without interrupting the previously focused application.
///
/// Closing logic — whichever fires first wins:
/// - Alt released (key-released handler or no-key timer after 150 ms)
/// - Escape key
/// - Mouse click on an icon
/// - Pointer leaving the switcher surface (closes without focus change)
fn build_window(app: &Application, groups: Vec<(String, Vec<WindowEntry>)>) {
    let windows = flat_windows(&groups);
    if windows.is_empty() { return; }
    let n = windows.len();

    // Start selection on the second-most-recently used window (fhid > 0 minimum),
    // which is the natural Alt+Tab target when the switcher first opens.
    let initial = windows.iter().enumerate()
        .filter(|(_, w)| w.4 > 0)
        .min_by_key(|(_, w)| w.4)
        .map(|(i, _)| i)
        .unwrap_or(0);

    // ── Shared state (all Rc — GTK is single-threaded) ────────────────────
    let selected:     Rc<Cell<usize>>                  = Rc::new(Cell::new(initial));
    let held_keys:    Rc<RefCell<HashSet<gdk::Key>>>   = Rc::new(RefCell::new(HashSet::new()));
    let no_key_src:   Rc<Cell<Option<glib::SourceId>>> = Rc::new(Cell::new(None));
    let socket_src:   Rc<Cell<Option<glib::SourceId>>> = Rc::new(Cell::new(None));
    let poll_src:     Rc<Cell<Option<glib::SourceId>>> = Rc::new(Cell::new(None));
    // Guard against activate_fn being called twice (e.g. key_released and poll
    // timer firing in the same GLib iteration).
    let closed:       Rc<Cell<bool>>                   = Rc::new(Cell::new(false));
    let frames:       Rc<RefCell<Vec<GtkBox>>>         = Rc::new(RefCell::new(Vec::new()));
    let windows_rc:   Rc<Vec<WindowEntry>>             = Rc::new(windows);
    // Tracks whether the pointer is currently inside the switcher surface.
    // When false, closing the switcher must not focus any window (Escape semantics).
    let mouse_inside: Rc<Cell<bool>>                   = Rc::new(Cell::new(true));

    // ── Window + layer shell ───────────────────────────────────────────────
    let window = ApplicationWindow::builder()
        .application(app)
        .decorated(false)
        .build();

    window.init_layer_shell();
    window.set_namespace(Some("hypr-alttab"));
    window.set_layer(gtk4_layer_shell::Layer::Overlay);
    // OnDemand: the surface is mapped without grabbing the keyboard seat.
    // We call grab_focus() explicitly after present() so the window receives
    // key events while leaving the previously focused app visually active.
    window.set_keyboard_mode(gtk4_layer_shell::KeyboardMode::OnDemand);
    // No edge anchoring → the compositor centers the window.
    for edge in [gtk4_layer_shell::Edge::Top, gtk4_layer_shell::Edge::Bottom,
                 gtk4_layer_shell::Edge::Left, gtk4_layer_shell::Edge::Right] {
        window.set_anchor(edge, false);
    }

    // ── Layout ────────────────────────────────────────────────────────────
    let outer = GtkBox::new(Orientation::Vertical, 0);
    outer.set_margin_top(20);
    outer.set_margin_bottom(20);
    outer.set_margin_start(20);
    outer.set_margin_end(20);
    window.set_child(Some(&outer));

    let groups_box = GtkBox::new(Orientation::Horizontal, 0);
    groups_box.set_halign(gtk4::Align::Center);
    groups_box.set_hexpand(true);
    outer.append(&groups_box);

    let title_label = Label::new(None);
    title_label.set_halign(gtk4::Align::Center);
    title_label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    title_label.set_max_width_chars(60);
    title_label.set_margin_top(10);
    outer.append(&title_label);

    // ── Shared callbacks ──────────────────────────────────────────────────
    // Defined as `Rc<dyn Fn()>` so they can be cloned cheaply into multiple
    // event handlers without requiring the closures themselves to be Clone.

    // Highlight the currently selected frame and update the title label.
    let update_sel: Rc<dyn Fn()> = Rc::new({
        let frames     = Rc::clone(&frames);
        let windows_rc = Rc::clone(&windows_rc);
        let selected   = Rc::clone(&selected);
        let lbl        = title_label.clone();
        move || {
            let fr = frames.borrow();
            if fr.is_empty() { lbl.set_text(""); return; }
            let sel = selected.get() % fr.len();
            selected.set(sel);
            for (i, frame) in fr.iter().enumerate() {
                if i == sel { frame.add_css_class("selected-icon"); }
                else        { frame.remove_css_class("selected-icon"); }
            }
            let (cls, title, _, _, _) = &windows_rc[sel];
            lbl.set_text(&format!("{}  —  {}", cls, title));
        }
    });

    // Cancel background timers and remove the socket / PID files.
    let cleanup_fn: Rc<dyn Fn()> = Rc::new({
        let no_key_src = Rc::clone(&no_key_src);
        let socket_src = Rc::clone(&socket_src);
        let poll_src   = Rc::clone(&poll_src);
        move || {
            if let Some(src) = no_key_src.take() { src.remove(); }
            if let Some(src) = socket_src.take() { src.remove(); }
            if let Some(src) = poll_src.take()   { src.remove(); }
            let _ = std::fs::remove_file(switcher_socket_path());
            let _ = std::fs::remove_file(switcher_pidfile());
        }
    });

    // Hide the window, cancel timers, quit GTK, and (if the pointer is inside
    // the surface) delegate the actual window focus to a new `--focus-address`
    // child process.  Focus delegation is necessary because `app.quit()` tears
    // down the GLib main loop before IPC calls could complete in the same process.
    let activate_fn: Rc<dyn Fn()> = Rc::new({
        let window       = window.clone();
        let windows_rc   = Rc::clone(&windows_rc);
        let selected     = Rc::clone(&selected);
        let cleanup      = Rc::clone(&cleanup_fn);
        let app          = app.clone();
        let mouse_inside = Rc::clone(&mouse_inside);
        let closed       = Rc::clone(&closed);
        move || {
            if closed.get() { return; }
            closed.set(true);
            window.set_visible(false);
            cleanup();
            // Pointer left the window: close silently, no focus change.
            if !mouse_inside.get() {
                app.quit();
                return;
            }
            if windows_rc.is_empty() { app.quit(); return; }
            let addr = windows_rc[selected.get()].2.clone();
            app.quit();
            focus_window_after_exit(&addr);
        }
    });

    // ── Populate frames + per-icon mouse controllers ──────────────────────
    {
        let mut fr = frames.borrow_mut();
        let mut flat_idx: usize = 0;

        for (ws_idx, (ws_name, entries)) in groups.iter().enumerate() {
            if ws_idx > 0 {
                let sep = Separator::new(Orientation::Vertical);
                sep.set_margin_start(8);
                sep.set_margin_end(8);
                groups_box.append(&sep);
            }

            let col = GtkBox::new(Orientation::Vertical, 4);
            col.set_margin_start(8);
            col.set_margin_end(8);
            let ws_lbl = Label::new(Some(ws_name));
            ws_lbl.add_css_class("ws-label");
            ws_lbl.set_margin_bottom(4);
            col.append(&ws_lbl);

            let icons_row = GtkBox::new(Orientation::Horizontal, 8);
            icons_row.set_halign(gtk4::Align::Center);
            col.append(&icons_row);

            for (cls, title, _addr, hidden, _fhid) in entries {
                let frame = GtkBox::new(Orientation::Vertical, 4);
                frame.set_margin_top(4);
                frame.set_margin_bottom(4);
                frame.set_margin_start(4);
                frame.set_margin_end(4);
                frame.add_css_class("icon-frame");
                frame.append(&make_icon_widget(cls, title));
                if *hidden { frame.add_css_class("grouped-icon"); }

                let idx = flat_idx;

                // Hover → update selection highlight without activating.
                let hover = EventControllerMotion::new();
                let sel_h = Rc::clone(&selected);
                let upd_h = Rc::clone(&update_sel);
                hover.connect_enter(move |_, _, _| { sel_h.set(idx); upd_h(); });
                frame.add_controller(hover);

                // Click → immediately activate the window under the cursor.
                let click = GestureClick::new();
                let sel_c = Rc::clone(&selected);
                let act_c = Rc::clone(&activate_fn);
                click.connect_released(move |_, _, _, _| { sel_c.set(idx); act_c(); });
                frame.add_controller(click);

                icons_row.append(&frame);
                fr.push(frame);
                flat_idx += 1;
            }

            groups_box.append(&col);
        }
    }

    // Render the initial selection before the window becomes visible.
    update_sel();

    // ── Daemon socket (non-blocking polling) ──────────────────────────────
    // A new per-switcher socket receives "next" from the daemon when the user
    // presses Alt+Tab while the switcher is already open.  Polling every 16 ms
    // gives ≤1-frame latency without needing a background thread.
    {
        let path = switcher_socket_path();
        let _ = std::fs::remove_file(&path);
        if let Ok(listener) = UnixListener::bind(&path) {
            let _ = listener.set_nonblocking(true);
            let selected_c   = Rc::clone(&selected);
            let update_sel_c = Rc::clone(&update_sel);
            let windows_rc_c = Rc::clone(&windows_rc);
            let src = glib::timeout_add_local(Duration::from_millis(16), move || {
                match listener.accept() {
                    Ok((mut conn, _)) => {
                        let mut buf = [0u8; 16];
                        let n = conn.read(&mut buf).unwrap_or(0);
                        if std::str::from_utf8(&buf[..n]).unwrap_or("").trim() == "next" {
                            let cnt = windows_rc_c.len().max(1);
                            selected_c.set((selected_c.get() + 1) % cnt);
                            update_sel_c();
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(_) => return glib::ControlFlow::Break,
                }
                glib::ControlFlow::Continue
            });
            socket_src.set(Some(src));
        }
    }

    // ── No-key timer ──────────────────────────────────────────────────────
    // Started immediately so that if the user releases Alt before any key
    // event reaches the overlay (race with compositor focus grant), the
    // switcher still closes.  The timer is reset on every key-press.
    {
        let activate  = Rc::clone(&activate_fn);
        let held_keys = Rc::clone(&held_keys);
        let window2   = window.clone();
        let src_cell  = Rc::clone(&no_key_src);
        let src = glib::timeout_add_local(Duration::from_millis(150), move || {
            src_cell.set(None);
            // Double-check GDK's modifier state to guard against the case where
            // Alt was released but key_released was never delivered to us.
            let kb = gtk4::prelude::WidgetExt::display(&window2)
                .default_seat()
                .and_then(|s| s.keyboard());
            let gdk_alt = kb.map_or(false, |kb| {
                kb.modifier_state().contains(gdk::ModifierType::ALT_MASK)
            });
            if held_keys.borrow().is_empty() && !gdk_alt {
                activate();
            }
            glib::ControlFlow::Break
        });
        no_key_src.set(Some(src));
    }

    // ── Alt-state poll timer ──────────────────────────────────────────────
    // Handles the case where keyboard focus left the overlay (e.g. the user
    // clicked outside the surface), so key_released is never delivered here.
    // Checks GDK modifier state every 200 ms and closes if Alt is no longer held.
    {
        let activate = Rc::clone(&activate_fn);
        let window3  = window.clone();
        let src = glib::timeout_add_local(Duration::from_millis(200), move || {
            let kb = gtk4::prelude::WidgetExt::display(&window3)
                .default_seat()
                .and_then(|s| s.keyboard());
            // When the overlay loses keyboard focus, Wayland stops sending modifier
        // updates to our surface so modifier_state() may return stale/empty
        // state. Default to true (Alt held) when the device is unavailable so
        // we never close while Alt is physically pressed.
        let gdk_alt = kb.map_or(true, |kb| {
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

    // ── Keyboard controller ───────────────────────────────────────────────
    {
        let ctrl = EventControllerKey::new();

        let sel1      = Rc::clone(&selected);
        let held1     = Rc::clone(&held_keys);
        let nk_src1   = Rc::clone(&no_key_src);
        let update1   = Rc::clone(&update_sel);
        let activate1 = Rc::clone(&activate_fn);
        let cleanup1  = Rc::clone(&cleanup_fn);
        let app1      = app.clone();

        ctrl.connect_key_pressed(move |_, keyval, _kc, _st| {
            // A key was pressed → cancel the pending no-key timer.
            if let Some(src) = nk_src1.take() { src.remove(); }

            if keyval == gdk::Key::Escape {
                cleanup1();
                app1.quit();
                return glib::Propagation::Stop;
            }

            held1.borrow_mut().insert(keyval);

            let cur = sel1.get();
            if keyval == gdk::Key::Tab || keyval == gdk::Key::Right {
                sel1.set((cur + 1) % n.max(1));
                update1();
                return glib::Propagation::Stop;
            }
            if keyval == gdk::Key::ISO_Left_Tab || keyval == gdk::Key::Left {
                sel1.set((cur + n.max(1) - 1) % n.max(1));
                update1();
                return glib::Propagation::Stop;
            }
            if keyval == gdk::Key::Return {
                activate1();
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });

        let held2     = Rc::clone(&held_keys);
        let activate2 = Rc::clone(&activate_fn);
        ctrl.connect_key_released(move |_, keyval, _kc, state| {
            held2.borrow_mut().remove(&keyval);
            // `state` still includes the modifier being released in this event,
            // so we must subtract it manually to detect "Alt fully released".
            let alt_releasing = keyval == gdk::Key::Alt_L || keyval == gdk::Key::Alt_R;
            let alt_held = state.contains(gdk::ModifierType::ALT_MASK) && !alt_releasing;
            if held2.borrow().is_empty() && !alt_held {
                activate2();
            }
        });

        window.add_controller(ctrl);
    }

    // ── Window-level pointer tracking ─────────────────────────────────────
    // When the pointer leaves the switcher surface, the next close event
    // (Alt release, timer, etc.) must not focus any window — same as Escape.
    {
        let motion = EventControllerMotion::new();
        let mi_enter = Rc::clone(&mouse_inside);
        let mi_leave = Rc::clone(&mouse_inside);
        motion.connect_enter(move |_, _, _| { mi_enter.set(true); });
        motion.connect_leave(move |_| { mi_leave.set(false); });
        window.add_controller(motion);
    }

    window.present();
    // Explicitly request keyboard focus after the surface is mapped.
    // With KeyboardMode::OnDemand the compositor does not grant the keyboard
    // seat automatically; grab_focus() triggers the grant without visually
    // stealing focus from the previously active window.
    window.grab_focus();
}

// ─── Public entry point ───────────────────────────────────────────────────────

/// Initialize GTK, load CSS, and run the switcher overlay.
///
/// This function blocks until the switcher is closed (Alt released, Escape,
/// or click).  It is called as `alttab --show` from the daemon.
pub fn run_switcher() {
    let groups = get_windows();
    if flat_windows(&groups).is_empty() {
        return;
    }

    let pidfile = switcher_pidfile();
    let _ = std::fs::write(&pidfile, format!("{}", std::process::id()));

    let app = Application::builder()
        .application_id("org.hypr.alttab")
        .build();

    app.connect_activate(move |app| {
        // Disable animations: the overlay appears and disappears instantly,
        // so animations would only add perceived latency.
        if let Some(settings) = gtk4::Settings::default() {
            settings.set_gtk_enable_animations(false);
        }

        let theme  = parse_mako_colors();
        let bg     = &theme.background;
        let border = &theme.border;
        let text   = &theme.text;

        let css_str = format!(
            "window {{ background-color: {bg}; border: 2px solid {border}; border-radius: 16px; }}\
             label {{ color: {text}; }}\
             .ws-label {{ color: alpha({text}, 0.5); font-size: 11px; }}\
             .icon-frame {{ padding: 10px 12px; border-radius: 12px; }}\
             .selected-icon {{ background-color: alpha({border}, 0.25); }}\
             .selected-icon:hover {{ background-color: alpha({border}, 0.4); }}\
             .grouped-icon {{ opacity: 0.75; border: 1px solid alpha({border}, 0.45); border-radius: 8px; }}"
        );

        let css = CssProvider::new();
        // load_from_data is used instead of load_from_string because
        // load_from_string is gated behind the "v4_12" feature flag.
        css.load_from_data(&css_str);
        gtk4::style_context_add_provider_for_display(
            &gdk::Display::default().unwrap(),
            &css,
            gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );

        build_window(app, groups.clone());
    });

    app.run_with_args::<&str>(&[]);
    let _ = std::fs::remove_file(&pidfile);
}
