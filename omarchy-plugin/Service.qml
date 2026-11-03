import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "logic.js" as Logic

Item {
    id: root

    property var shell: null

    property bool open: false
    onOpenChanged: Hyprland.dispatch('hl.dsp.submap("' + (open ? "alttab" : "reset") + '")')
    property var groups: []
    property var flat: []
    property int selected: 0

    property bool highlight: false
    property int fadeOpacity: 80
    property int fadeDuration: 250

    Highlight {
        id: highlighter
        service: root
        enabled: root.highlight
        fadeOpacity: root.fadeOpacity
        fadeDuration: root.fadeDuration
    }

    readonly property alias icons: iconResolver

    IconResolver {
        id: iconResolver
        shell: root.shell
    }

    // Window previews: tile height for the current opening (shrunk so the row
    // fits the focused monitor) and Hyprland address -> Wayland toplevel handle
    // for the screencopy source.
    readonly property int maxThumbHeight: 150
    property int thumbHeight: maxThumbHeight
    property var toplevelByAddr: ({})
    property bool previews: true
    property var modules: Logic.defaultModules()

    FileView {
        id: configFile
        path: Quickshell.env("HOME") + "/.config/omarchy/alttab.json"
        watchChanges: true
        printErrors: false
        onLoaded: root.applyConfig(Logic.parseConfig(text()))
        onFileChanged: reload()
        onLoadFailed: root.applyConfig(Logic.parseConfig(""))
    }

    // Optional modules, each loaded only when enabled in alttab.json. A module
    // may define refresh(flat), called when the overlay opens, and expose
    // badges (address -> true), drawn as a dot on those windows.
    Instantiator {
        id: moduleLoaders
        model: Logic.moduleList()
        delegate: Loader {
            required property var modelData
            active: !!root.modules[modelData.id]
            source: Qt.resolvedUrl("modules/" + modelData.file)
        }
    }

    function refreshModules(flat) {
        for (let i = 0; i < moduleLoaders.count; i++) {
            const m = moduleLoaders.objectAt(i).item;
            if (m && typeof m.refresh === "function") m.refresh(flat);
        }
    }

    function hasBadge(addr) {
        for (let i = 0; i < moduleLoaders.count; i++) {
            const loader = moduleLoaders.objectAt(i);
            const m = loader ? loader.item : null;
            if (m && m.badges && m.badges[addr]) return true;
        }
        return false;
    }

    function fitThumbs(flat, groupCount) {
        const mon = Hyprland.focusedMonitor;
        const availW = mon ? mon.width / (mon.scale || 1) * 0.92 : 1800;
        root.thumbHeight = root.previews
            ? Logic.fitThumbHeight(flat, groupCount, root.maxThumbHeight, availW)
            : 64;
        if (root.previews) root.refreshToplevels();
    }

    function applyConfig(config) {
        root.previews = config.previews;
        root.highlight = config.highlight;
        root.fadeOpacity = config.fadeOpacity;
        root.fadeDuration = config.fadeDuration;
        root.modules = config.modules;
    }

    // Write one key to alttab.json, keeping the others.
    function saveConfig(key, value) {
        let data = {};
        try { data = JSON.parse(configFile.text()) || {}; } catch (e) {}
        data[key] = value;
        configFile.setText(JSON.stringify(data, null, 2) + "\n");
    }

    // Switch between previews and icons, persisted to alttab.json.
    function togglePreviews() {
        root.previews = !root.previews;
        saveConfig("previews", root.previews);
        if (root.previews) Hyprland.refreshToplevels();
        root.fitThumbs(root.flat, root.groups.length);
    }

    function toggleHighlight() {
        root.highlight = !root.highlight;
        saveConfig("highlight", root.highlight);
    }

    // Close the selected window and drop it from the list; the overlay stays open.
    function closeSelected() {
        const entry = flat[selected];
        if (!entry) return;
        Hyprland.dispatch('hl.dsp.window.close({ window = "address:' + entry.addr + '" })');
        highlighter.windowClosed(entry.addr);
        const groups = Logic.removeEntry(root.groups, entry.addr);
        const remaining = Logic.flatten(groups);
        if (!remaining.length) {
            root.close(false);
            return;
        }
        root.fitThumbs(remaining, groups.length);
        root.groups = groups;
        root.flat = remaining;
        root.selected = Math.min(root.selected, remaining.length - 1);
    }

    function refreshToplevels() {
        const map = {};
        for (const t of Hyprland.toplevels.values)
            if (t && t.wayland) map[String(t.address).replace(/^0x/, "")] = t.wayland;
        toplevelByAddr = map;
    }

    // Keyboard state observed by the overlay. The initial ALT press predates
    // the surface, so modifier state is only known from received events.
    property var heldKeys: ({})
    property bool sawKeyEvent: false
    property bool modsHeld: false

    // Modifier press/release keycodes are not symmetric under some xkb options
    // (shift:both_capslock_cancel releases Shift as CapsLock); modsHeld covers them.
    function isModifierKey(key) {
        return key === Qt.Key_Shift || key === Qt.Key_Control || key === Qt.Key_Alt
            || key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R
            || key === Qt.Key_CapsLock || key === Qt.Key_AltGr;
    }

    function heldEmpty() {
        for (const k in heldKeys) return false;
        return true;
    }

    function next() { if (flat.length) selected = (selected + 1) % flat.length }
    function prev() { if (flat.length) selected = (selected + flat.length - 1) % flat.length }

    property bool pendingReverseOpen: false

    function requestOpen(reverse) {
        root.pendingReverseOpen = !!reverse;
        highlighter.beforeOpen();
        if (root.previews) Hyprland.refreshToplevels();
        if (root.shell && root.shell.appLibrary) root.shell.appLibrary.refreshIcons();
        clientsProc.running = true;
    }

    // doFocus=false: Escape semantics — close without focusing.
    function close(doFocus) {
        if (!open) return;
        const entry = (doFocus && flat.length) ? flat[selected] : null;
        open = false;
        const back = entry ? null : highlighter.returnTarget();
        if (!entry && !back) return;
        pendingAddr = entry ? entry.addr : back.addr;
        pendingGroupIdx = entry ? entry.groupIdx : 0;
        pendingWs = back ? back.ws : -1;
        focusTimer.start();
    }

    property string pendingAddr: ""
    property int pendingGroupIdx: 0
    property int pendingWs: -1

    // Dispatch after the overlay surface is gone: tearing down the exclusive
    // keyboard grab makes Hyprland restore focus to the previously active
    // window, which re-raises its group tab and undoes a same-group switch.
    // hl.dsp.focus silently ignores hidden group tabs (Hyprland ≥0.56), so
    // switch the group's active tab first. Two dispatches: the payload is
    // evaluated as a single Lua expression. Focus does not raise floating windows.
    Timer {
        id: focusTimer
        interval: 100
        onTriggered: {
            if (!root.pendingAddr) {
                Hyprland.dispatch('hl.dsp.focus({ workspace = "' + root.pendingWs + '" })');
                return;
            }
            if (root.pendingGroupIdx)
                Hyprland.dispatch('hl.dsp.group.active({ window = "address:' + root.pendingAddr + '", index = ' + root.pendingGroupIdx + ' })');
            Hyprland.dispatch('hl.dsp.focus({ window = "address:' + root.pendingAddr + '" })');
            Hyprland.dispatch('hl.dsp.window.bring_to_top()');
        }
    }

    // One shortcut serves ALT+Tab and SUPER+Tab. While the overlay is open the
    // exclusive keyboard grab keeps the compositor bind from refiring, but stay
    // defensive in case an event slips through before the grant.
    GlobalShortcut {
        appid: "omarchy-alttab"
        name: "next"
        onPressed: {
            if (root.open) {
                // The compositor bind refired: the modifier is necessarily held.
                root.sawKeyEvent = true;
                root.modsHeld = true;
                root.next();
            } else {
                root.requestOpen();
            }
        }
    }

    // Mirrors "next" for the reverse direction (e.g. ALT+SHIFT+TAB); a cold
    // press opens the overlay on the last window of the list.
    GlobalShortcut {
        appid: "omarchy-alttab"
        name: "prev"
        onPressed: {
            if (root.open) {
                root.sawKeyEvent = true;
                root.modsHeld = true;
                root.prev();
            } else {
                root.requestOpen(true);
            }
        }
    }

    // The Lua binding snippet tags its binds with the "Alt-Tab switcher"
    // description; its absence means the user enabled the plugin without
    // installing alttab-bindings.lua.
    Timer {
        interval: 3000
        running: true
        onTriggered: bindsCheck.running = true
    }

    Process {
        id: bindsCheck
        command: ["hyprctl", "-j", "binds"]
        stdout: StdioCollector {
            onStreamFinished: {
                let binds = [];
                try { binds = JSON.parse(text); } catch (e) { return; }
                if (!binds.some(b => b.description === "Alt-Tab switcher"))
                    missingBindNotify.running = true;
            }
        }
    }

    Process {
        id: missingBindNotify
        command: ["sh", "-c",
            'action=$(notify-send -u critical -A default="Open README" "hyprland-alttab" ' +
            '"No keybinding found. Add alttab-bindings.lua to your Hyprland config."); ' +
            '[ "$action" = "default" ] && xdg-open ' +
            '"https://github.com/c4software/hyprland-alttab/blob/main/omarchy-plugin/README.md"']
    }

    Process {
        id: clientsProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                let clients = [];
                try { clients = JSON.parse(text); } catch (e) { return; }
                const activeWs = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
                const groups = Logic.groupClients(clients, activeWs);
                const flat = Logic.flatten(groups);
                if (!flat.length) {
                    highlighter.openCancelled();
                    return;
                }
                iconResolver.readAgentPrograms(clients);
                root.fitThumbs(flat, groups.length);
                root.refreshModules(flat);
                root.groups = groups;
                root.flat = flat;
                root.selected = root.pendingReverseOpen ? flat.length - 1 : Logic.initialSelection(flat);
                root.pendingReverseOpen = false;
                root.heldKeys = {};
                root.sawKeyEvent = false;
                root.modsHeld = false;
                const origin = clients.find(c => c.focusHistoryID === 0);
                highlighter.opened(origin ? origin.address : "", activeWs,
                    Hyprland.focusedMonitor ? Hyprland.focusedMonitor.id : -1);
                root.open = true;
            }
        }
    }

    LazyLoader {
        active: root.open

        Overlay {
            service: root
        }
    }
}
