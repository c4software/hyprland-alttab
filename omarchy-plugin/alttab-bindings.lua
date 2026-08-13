-- hyprland-alttab — bindings to inject into the Hyprland Lua config
-- (~/.config/hypr/customisation.lua or bindings.lua), Hyprland ≥ 0.56.

-- The "Alt-Tab switcher" description acts as a sentinel: the plugin checks
-- for it in `hyprctl binds` to detect that the binding is installed.
hl.unbind("ALT + TAB")
o.bind("ALT + TAB", "Alt-Tab switcher", hl.dsp.global("omarchy-alttab:next"), { repeating = true })

hl.unbind("SUPER + TAB")
o.bind("SUPER + TAB", "Alt-Tab switcher", hl.dsp.global("omarchy-alttab:next"), { repeating = true })

hl.layer_rule({ match = { namespace = "omarchy-alttab" }, no_anim = true })
