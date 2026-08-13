-- hyprland-alttab — bindings à injecter dans la config Hyprland Lua
-- (~/.config/hypr/customisation.lua ou bindings.lua), Hyprland ≥ 0.56.

-- La description "Alt-Tab switcher" sert de sentinelle : le plugin vérifie sa
-- présence dans `hyprctl binds` pour détecter que le binding est installé.
hl.unbind("ALT + TAB")
o.bind("ALT + TAB", "Alt-Tab switcher", hl.dsp.global("omarchy-alttab:next"), { repeating = true })

hl.unbind("SUPER + TAB")
o.bind("SUPER + TAB", "Alt-Tab switcher", hl.dsp.global("omarchy-alttab:next"), { repeating = true })

hl.layer_rule({ match = { namespace = "omarchy-alttab" }, no_anim = true })
