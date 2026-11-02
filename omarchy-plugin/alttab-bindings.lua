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

-- Entered while the overlay is open. The overlay takes no keyboard focus, so
-- focus can follow the selection; its keys live here instead. Escape resets
-- the submap itself, which the plugin takes as cancel: it stays a way out if
-- the shell dies mid-switch.
local function switcher(action)
    return hl.dsp.global("omarchy-alttab:" .. action)
end

hl.define_submap("alttab", function()
    for _, mods in ipairs({ "ALT", "SUPER" }) do
        hl.bind(mods .. " + TAB", switcher("next"), { repeating = true })
        hl.bind(mods .. " + SHIFT + TAB", switcher("prev"), { repeating = true })
        -- Releasing the modifier commits the selection.
        hl.bind(mods .. " + " .. mods .. "_L", switcher("commit"), { release = true, transparent = true })
        hl.bind(mods .. " + " .. mods .. "_R", switcher("commit"), { release = true, transparent = true })
    end
    hl.bind("RIGHT", switcher("next"), { repeating = true, ignore_mods = true })
    hl.bind("LEFT", switcher("prev"), { repeating = true, ignore_mods = true })
    hl.bind("RETURN", switcher("commit"), { ignore_mods = true })
    hl.bind("KP_ENTER", switcher("commit"), { ignore_mods = true })
    hl.bind("P", switcher("toggle-previews"), { ignore_mods = true })
    hl.bind("Q", switcher("close-selected"), { ignore_mods = true })
    hl.bind("ESCAPE", hl.dsp.submap("reset"), { ignore_mods = true, description = "Alt-Tab switcher (exit)" })
    -- Other keys would reach the window under live focus.
    hl.bind("catchall", hl.dsp.no_op())
end)

hl.layer_rule({ match = { namespace = "omarchy-alttab" }, no_anim = true })
