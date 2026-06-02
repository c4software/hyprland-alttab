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

// ─── Icon ────────────────────────────────────────────────────────────────────

fn make_icon_widget(cls: &str) -> Image {
    let img = Image::new();
    img.set_pixel_size(64);

    let cls_lower = cls.to_lowercase();
    let no_dash   = cls.replace('-', "");
    let dot_part  = cls.split('.').next().unwrap_or(cls);

    for candidate in &[cls, cls_lower.as_str(), no_dash.as_str(), dot_part] {
        if candidate.is_empty() {
            continue;
        }
        if let Some(app) = gio_unix::DesktopAppInfo::new(&format!("{}.desktop", candidate)) {
            if let Some(icon) = gio::prelude::AppInfoExt::icon(&app) {
                img.set_from_gicon(&icon);
                return img;
            }
        }
    }

    if let Some(display) = gdk::Display::default() {
        let theme = gtk4::IconTheme::for_display(&display);
        for name in &[cls, cls_lower.as_str(),
                       cls.split('-').next().unwrap_or(cls),
                       cls.split('.').last().unwrap_or(cls)] {
            if !name.is_empty() && theme.has_icon(name) {
                img.set_icon_name(Some(name));
                return img;
            }
        }
    }

    img.set_icon_name(Some("application-x-executable"));
    img
}

// ─── build_window ─────────────────────────────────────────────────────────────

fn build_window(app: &Application, groups: Vec<(String, Vec<WindowEntry>)>) {
    let windows = flat_windows(&groups);
    if windows.is_empty() {
        return;
    }
    let n = windows.len();

    let initial = windows.iter().enumerate()
        .filter(|(_, w)| w.4 > 0)
        .min_by_key(|(_, w)| w.4)
        .map(|(i, _)| i)
        .unwrap_or(0);

    // ── Shared state (Rc, main-thread only) ───────────────────────────────
    let selected:   Rc<Cell<usize>>                  = Rc::new(Cell::new(initial));
    let held_keys:  Rc<RefCell<HashSet<gdk::Key>>>   = Rc::new(RefCell::new(HashSet::new()));
    let no_key_src: Rc<Cell<Option<glib::SourceId>>> = Rc::new(Cell::new(None));
    let socket_src: Rc<Cell<Option<glib::SourceId>>> = Rc::new(Cell::new(None));
    let frames:     Rc<RefCell<Vec<GtkBox>>>         = Rc::new(RefCell::new(Vec::new()));
    let windows_rc: Rc<Vec<WindowEntry>>             = Rc::new(windows);

    // ── Window + layer shell ───────────────────────────────────────────────
    let window = ApplicationWindow::builder()
        .application(app)
        .decorated(false)
        .build();

    window.init_layer_shell();
    window.set_namespace(Some("hypr-alttab"));
    window.set_layer(gtk4_layer_shell::Layer::Overlay);
    // OnDemand: window does not steal focus on map; we grab it explicitly after present()
    window.set_keyboard_mode(gtk4_layer_shell::KeyboardMode::OnDemand);
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

    // ── Helpers (defined before frame loop so closures can capture them) ──

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

    let cleanup_fn: Rc<dyn Fn()> = Rc::new({
        let no_key_src = Rc::clone(&no_key_src);
        let socket_src = Rc::clone(&socket_src);
        move || {
            if let Some(src) = no_key_src.take() { src.remove(); }
            if let Some(src) = socket_src.take() { src.remove(); }
            let _ = std::fs::remove_file(switcher_socket_path());
            let _ = std::fs::remove_file(switcher_pidfile());
        }
    });

    let activate_fn: Rc<dyn Fn()> = Rc::new({
        let window     = window.clone();
        let windows_rc = Rc::clone(&windows_rc);
        let selected   = Rc::clone(&selected);
        let cleanup    = Rc::clone(&cleanup_fn);
        let app        = app.clone();
        move || {
            if windows_rc.is_empty() { return; }
            let addr = windows_rc[selected.get()].2.clone();
            window.set_visible(false);
            cleanup();
            app.quit();
            focus_window_after_exit(&addr);
        }
    });

    // ── Populate frames + mouse controllers ───────────────────────────────
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

            for (cls, _title, _addr, hidden, _fhid) in entries {
                let frame = GtkBox::new(Orientation::Vertical, 4);
                frame.set_margin_top(4);
                frame.set_margin_bottom(4);
                frame.set_margin_start(4);
                frame.set_margin_end(4);
                frame.add_css_class("icon-frame");
                frame.append(&make_icon_widget(cls));
                if *hidden { frame.add_css_class("grouped-icon"); }

                let idx = flat_idx;

                // Hover → select (highlight) without activating
                let hover = EventControllerMotion::new();
                let sel_h  = Rc::clone(&selected);
                let upd_h  = Rc::clone(&update_sel);
                hover.connect_enter(move |_, _, _| {
                    sel_h.set(idx);
                    upd_h();
                });
                frame.add_controller(hover);

                // Click → activate the hovered window
                let click = GestureClick::new();
                let sel_c  = Rc::clone(&selected);
                let act_c  = Rc::clone(&activate_fn);
                click.connect_released(move |_, _, _, _| {
                    sel_c.set(idx);
                    act_c();
                });
                frame.add_controller(click);

                icons_row.append(&frame);
                fr.push(frame);
                flat_idx += 1;
            }

            groups_box.append(&col);
        }
    }

    // Initial selection render
    update_sel();

    // ── Socket (non-blocking polling) ─────────────────────────────────────
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
    {
        let activate  = Rc::clone(&activate_fn);
        let held_keys = Rc::clone(&held_keys);
        let window2   = window.clone();
        let src_cell  = Rc::clone(&no_key_src);
        let src = glib::timeout_add_local(Duration::from_millis(150), move || {
            src_cell.set(None);
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

    // ── Key controller ────────────────────────────────────────────────────
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
            let alt_releasing = keyval == gdk::Key::Alt_L || keyval == gdk::Key::Alt_R;
            let alt_held = state.contains(gdk::ModifierType::ALT_MASK) && !alt_releasing;
            if held2.borrow().is_empty() && !alt_held {
                activate2();
            }
        });

        window.add_controller(ctrl);
    }

    window.present();
    // Explicitly request keyboard focus after the surface is mapped,
    // so we receive key events without having stolen focus on map.
    window.grab_focus();
}

// ─── run_switcher ─────────────────────────────────────────────────────────────

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
