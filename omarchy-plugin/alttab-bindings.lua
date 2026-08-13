-- hyprland-alttab — bindings à injecter dans la config Hyprland Lua
-- (~/.config/hypr/customisation.lua ou bindings.lua), Hyprland ≥ 0.56.

hl.unbind("ALT + TAB")
o.bind("ALT + TAB", nil, hl.dsp.global("omarchy-alttab:next"), { repeating = true })

hl.unbind("SUPER + TAB")
o.bind("SUPER + TAB", nil, hl.dsp.global("omarchy-alttab:next"), { repeating = true })

hl.layer_rule({ match = { namespace = "omarchy-alttab" }, no_anim = true })
