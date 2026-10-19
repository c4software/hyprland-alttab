-- hyprland-alttab — bindings to inject into the Hyprland Lua config
-- (~/.config/hypr/customisation.lua or bindings.lua), Hyprland ≥ 0.56.

-- The "Alt-Tab switcher" description acts as a sentinel: the plugin checks
-- for it in `hyprctl binds` to detect that the binding is installed.
hl.unbind("ALT + TAB")
o.bind("ALT + TAB", "Alt-Tab switcher", hl.dsp.global("omarchy-alttab:next"), { repeating = true })

hl.unbind("SUPER + TAB")
o.bind("SUPER + TAB", "Alt-Tab switcher", hl.dsp.global("omarchy-alttab:next"), { repeating = true })

hl.unbind("ALT + SHIFT + TAB")
o.bind("ALT + SHIFT + TAB", "Alt-Tab switcher (reverse)", hl.dsp.global("omarchy-alttab:prev"), { repeating = true })

hl.unbind("SUPER + SHIFT + TAB")
o.bind("SUPER + SHIFT + TAB", "Alt-Tab switcher (reverse)", hl.dsp.global("omarchy-alttab:prev"), { repeating = true })

-- Entered while the overlay is open so compositor binds (e.g. SUPER + P) don't
-- swallow the overlay's keys. Escape stays a way out if the shell dies mid-switch.
hl.define_submap("alttab", function()
    hl.bind("ESCAPE", hl.dsp.submap("reset"), { non_consuming = true, ignore_mods = true, description = "Alt-Tab switcher (exit)" })
end)

hl.layer_rule({ match = { namespace = "omarchy-alttab" }, no_anim = true })
