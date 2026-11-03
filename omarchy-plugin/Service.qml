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
    onOpenChanged: {
        Hyprland.dispatch('hl.dsp.submap("' + (open ? "alttab" : "reset") + '")');
        root.followReady = false;
        if (open) followTimer.restart();
        else fadeRestoreTimer.restart();
    }
    property var groups: []
    property var flat: []
    property int selected: 0

    // Selected window tagged "alttab-selected", the others "alttab-dim"; window rules style them.
    property bool highlight: false
    property int fadeOpacity: 80
    property int fadeDuration: 250
    onHighlightChanged: {
        if (open && highlight) prepareHighlight();
        updateHighlight();
    }
    property string highlightedAddr: ""
    property var dimmedAddrs: ({})
    readonly property string highlightTarget: open && highlight && flat[selected] ? flat[selected].addr : ""
    onHighlightTargetChanged: updateHighlight()
    onFlatChanged: updateHighlight()

    // Runs Lua statements in one dispatch, in order; dispatch expects a dispatcher back.
    function hyprBatch(statements) {
        const body = statements.filter(st => st).join(" ");
        if (body) Hyprland.dispatch("(function() " + body + " return hl.dsp.no_op() end)()");
    }

    function tagStatement(addr, tag) {
        if (!/^0x[0-9a-fA-F]+$/.test(String(addr))) return "";
        return 'hl.dispatch(hl.dsp.window.tag({ window = "address:' + addr + '", tag = "' + tag + '" }))';
    }

    property int originWs: -1
    property int originMon: -1
    property int shownWs: -1
    property string originAddr: ""

    // Switching workspace before the overlay holds the keyboard would move window focus.
    property bool followReady: false

    Timer {
        id: followTimer
        interval: 150
        onTriggered: {
            root.followReady = root.open;
            root.followWorkspace();
        }
    }

    function followWorkspace() {
        const entry = open && followReady ? flat[selected] : null;
        if (!entry || entry.ws <= 0 || entry.ws === shownWs || entry.mon !== originMon) return;
        Hyprland.dispatch('hl.dsp.focus({ workspace = "' + entry.ws + '" })');
        shownWs = entry.ws;
    }

    function updateHighlight() {
        const batch = [];
        const moved = highlightTarget !== highlightedAddr;
        if (moved) {
            if (highlightedAddr) batch.push(tagStatement(highlightedAddr, "-alttab-selected"));
            if (highlightTarget) batch.push(tagStatement(highlightTarget, "+alttab-selected"));
            highlightedAddr = highlightTarget;
        }
        const wanted = {};
        if (open && highlight)
            for (const e of flat)
                if (e.addr !== highlightTarget) wanted[e.addr] = true;
        for (const a in dimmedAddrs)
            if (!wanted[a]) batch.push(tagStatement(a, "-alttab-dim"));
        for (const a in wanted)
            if (!dimmedAddrs[a]) batch.push(tagStatement(a, "+alttab-dim"));
        dimmedAddrs = wanted;
        hyprBatch(batch);
        if (moved) followWorkspace();
    }

    readonly property string accentHex: {
        const hex = String(Color.accent).replace("#", "").slice(-6);
        return /^[0-9a-fA-F]{6}$/.test(hex) ? hex : "ffffff";
    }
    // Rules are redefined on each opening: a dispatch sent while the shell starts is lost.
    function prepareHighlight() {
        defineHighlightRule();
        setFadeSwitch(true);
    }

    function defineHighlightRule() {
        const color = "rgb(" + accentHex + ")";
        const alpha = (fadeOpacity / 100).toFixed(2) + " override";
        hyprBatch([
            'hl.window_rule({ name = "alttab-selected", match = { tag = "alttab-selected" }, border_color = "' + color + ' ' + color + '" })',
            'hl.window_rule({ name = "alttab-dim", match = { tag = "alttab-dim" }, opacity = "' + alpha + ' ' + alpha + '" })']);
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "configreloaded") return;
            // The reload reapplied the user's fadeSwitch.
            if (root.fadeSwitchOn) fadeStateFile.setText("");
            root.fadeSwitchOn = false;
            root.fadeSwitchKnown = false;
            fadeSwitchRead.running = true;
        }
    }

    // Tags left by a shell that died mid-switch.
    Process {
        id: staleTagsProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                let clients = [];
                try { clients = JSON.parse(text); } catch (e) { return; }
                const batch = [];
                for (const c of clients)
                    for (const t of c.tags || [])
                        if (t === "alttab-selected" || t === "alttab-dim") batch.push(root.tagStatement(c.address, "-" + t));
                root.hyprBatch(batch);
            }
        }
    }

    // fadeSwitch animates the opacity change; only enabled when the user has it off.
    property bool fadeSwitchKnown: false
    property bool fadeSwitchUserOn: false
    property bool fadeSwitchOn: false

    // Exists while the plugin has fadeSwitch on, so a restart after a crash turns it back off.
    FileView {
        id: fadeStateFile
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-alttab-fadeswitch"
        printErrors: false
        onLoaded: {
            if (text().trim() === "") {
                fadeSwitchRead.running = true;
                return;
            }
            root.fadeSwitchKnown = true;
            root.fadeSwitchUserOn = false;
            root.fadeSwitchOn = true;
            root.setFadeSwitch(false);
        }
        onLoadFailed: fadeSwitchRead.running = true
    }

    Process {
        id: fadeSwitchRead
        command: ["hyprctl", "animations", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const a = JSON.parse(text)[0].find(x => x.name === "fadeSwitch");
                    root.fadeSwitchUserOn = !!(a && a.enabled);
                    root.fadeSwitchKnown = true;
                } catch (e) {}
                if (root.open && root.highlight) root.setFadeSwitch(true);
            }
        }
    }

    function setFadeSwitch(on) {
        if (on) {
            if (fadeSwitchOn || !fadeSwitchKnown || fadeSwitchUserOn || fadeDuration <= 0) return;
            fadeStateFile.setText("1");
            fadeSwitchOn = true;
            hyprBatch(['hl.animation({ leaf = "fadeSwitch", enabled = true, speed = ' + (fadeDuration / 100).toFixed(2) + ', bezier = "quick" })']);
        } else {
            if (!fadeSwitchOn) return;
            fadeStateFile.setText("");
            fadeSwitchOn = false;
            hyprBatch(['hl.animation({ leaf = "fadeSwitch", enabled = false })']);
        }
    }

    Timer {
        id: fadeRestoreTimer
        interval: root.fadeDuration + 150
        onTriggered: if (!root.open) root.setFadeSwitch(false)
    }

    Component.onCompleted: staleTagsProc.running = true

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

    // Omarchy's default coding agent and default terminal, for the icons of
    // agent windows (see iconPathFor).
    property string defaultAgent: ""
    property string defaultTerminal: ""

    FileView {
        path: Quickshell.env("HOME") + "/.config/omarchy/defaults/agent"
        watchChanges: true
        printErrors: false
        onLoaded: root.defaultAgent = Logic.firstListEntry(text())
        onFileChanged: reload()
        onLoadFailed: root.defaultAgent = ""
    }

    FileView {
        path: Quickshell.env("HOME") + "/.config/xdg-terminals.list"
        watchChanges: true
        printErrors: false
        onLoaded: root.defaultTerminal = Logic.firstListEntry(text())
        onFileChanged: reload()
        onLoadFailed: root.defaultTerminal = ""
    }

    // Parent pid -> child programs of agent windows' terminals, read on each
    // opening: the terminal process runs the agent.
    property var childPrograms: ({})

    Process {
        id: childProc
        stdout: StdioCollector {
            onStreamFinished: root.childPrograms = Logic.childPrograms(text)
        }
    }

    // Only the children of agent windows' terminals are read.
    function readAgentPrograms(clients) {
        const pids = clients.filter(c => c.class === "org.omarchy.agent" && c.pid > 0).map(c => c.pid);
        root.childPrograms = ({});
        if (!pids.length) return;
        childProc.command = ["ps", "--ppid", pids.join(","), "-o", "ppid=,args="];
        childProc.running = true;
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
        if (entry.addr === root.originAddr) root.originAddr = "";
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
        fadeRestoreTimer.stop();
        if (!root.fadeSwitchKnown && !fadeSwitchRead.running) fadeSwitchRead.running = true;
        if (root.highlight) root.prepareHighlight();
        if (root.previews) Hyprland.refreshToplevels();
        if (root.shell && root.shell.appLibrary) root.shell.appLibrary.refreshIcons();
        clientsProc.running = true;
    }

    // doFocus=false: Escape semantics — close without focusing.
    function close(doFocus) {
        if (!open) return;
        const entry = (doFocus && flat.length) ? flat[selected] : null;
        open = false;
        if (!entry && shownWs === originWs) return;
        pendingAddr = entry ? entry.addr : originAddr;
        pendingGroupIdx = entry ? entry.groupIdx : 0;
        focusTimer.start();
    }

    property string pendingAddr: ""
    property int pendingGroupIdx: 0

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
                Hyprland.dispatch('hl.dsp.focus({ workspace = "' + root.originWs + '" })');
                return;
            }
            if (root.pendingGroupIdx)
                Hyprland.dispatch('hl.dsp.group.active({ window = "address:' + root.pendingAddr + '", index = ' + root.pendingGroupIdx + ' })');
            Hyprland.dispatch('hl.dsp.focus({ window = "address:' + root.pendingAddr + '" })');
            Hyprland.dispatch('hl.dsp.window.bring_to_top()');
        }
    }

    // Chromium names --app windows "chrome-<host>_<path, / → _>-<profile>",
    // e.g. https://outlook.office.com/mail/ → chrome-outlook.office.com__mail_-Default.
    function chromeAppKey(url) {
        const m = /^https?:\/\/([^\/?#]+)([^?#]*)/.exec(url);
        return m ? (m[1] + "_" + (m[2] || "/").replace(/\//g, "_")).toLowerCase() : "";
    }

    function isWordChar(c) {
        return !!c && (c.toLowerCase() !== c.toUpperCase() || (c >= "0" && c <= "9"));
    }

    // True if needle occurs in hay as a whole word: a plain substring test
    // matched the app "X" inside "Inbox".
    function containsWord(hay, needle) {
        for (let i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + 1)) {
            if (!isWordChar(hay[i - 1]) && !isWordChar(hay[i + needle.length]))
                return true;
        }
        return false;
    }

    // Returns "" when nothing resolves (e.g. the configured icon theme is missing).
    // Qt's icon cache never re-scans, so apps installed after the shell started
    // fall back to the shell's appLibrary, which keeps a live on-disk index.
    function resolveIcon(name) {
        if (!name) return "";
        if (name.startsWith("/")) return "file://" + name;
        const p = Quickshell.iconPath(name, true);
        if (p) return p;
        const lib = root.shell ? root.shell.appLibrary : null;
        const found = lib ? lib.iconSource(name) : "";
        return found && found !== Quickshell.iconPath("application-x-executable", true) ? found : "";
    }

    // Icon cascade: desktop entry by id variants → StartupWMClass scan →
    // Omarchy terminal app entry → for agent windows, the agent the window
    // runs, the default agent, then the default terminal → Chrome web app URL
    // from Exec → app Name as whole word in title (longest wins) → icon theme
    // variants → generic.
    function iconPathFor(cls, title, pid) {
        const clsLower = cls.toLowerCase();
        for (const v of [cls, clsLower, cls.replace(/-/g, ""), cls.split(".")[0]]) {
            if (!v) continue;
            const e = DesktopEntries.byId(v);
            const p = e ? resolveIcon(e.icon) : "";
            if (p) return p;
        }
        const all = DesktopEntries.applications.values;
        for (const e of all) {
            if (e.startupClass && e.startupClass.toLowerCase() === clsLower) {
                const p = resolveIcon(e.icon);
                if (p) return p;
            }
        }
        // Omarchy terminal apps run in the terminal's process under a class of
        // their own, which no StartupWMClass names.
        const entries = Array.from(all);
        const tui = Logic.terminalAppEntry(cls, entries);
        const tuiIcon = tui ? resolveIcon(tui.icon) : "";
        if (tuiIcon) return tuiIcon;
        // omarchy-agent gives every agent the same class.
        if (cls === "org.omarchy.agent") {
            for (const name of [Logic.windowProgram(root.childPrograms, pid), root.defaultAgent]) {
                if (!name || name.includes("/")) continue;
                const e = Logic.programEntry(name, entries);
                const p = e ? resolveIcon(e.icon) : resolveIcon(name);
                if (p) return p;
            }
            const terminal = root.defaultTerminal ? DesktopEntries.byId(root.defaultTerminal) : null;
            const p = terminal ? resolveIcon(terminal.icon) : "";
            if (p) return p;
        }
        // Entries with a StartupWMClass were matched exactly above; skipping them
        // keeps a profile-specific launcher from claiming another profile's window.
        const chrome = /^chrome-(.+)-[^-]+$/.exec(clsLower);
        if (chrome) {
            for (const e of all) {
                if (e.startupClass) continue;
                const url = /https?:\/\/[^\s"']+/.exec(e.execString || "");
                if (url && chromeAppKey(url[0]) === chrome[1]) {
                    const p = resolveIcon(e.icon);
                    if (p) return p;
                }
            }
        }
        const titleLower = (title || "").toLowerCase();
        if (titleLower) {
            let best = "";
            let bestLen = 0;
            for (const e of all) {
                const n = (e.name || "").toLowerCase();
                if (!n || n.length <= bestLen || !containsWord(titleLower, n)) continue;
                const p = resolveIcon(e.icon);
                if (p) {
                    best = p;
                    bestLen = n.length;
                }
            }
            if (best) return best;
        }
        // The class is set by the app: only a bare theme name may reach the loader.
        for (const v of [cls, clsLower, cls.split("-")[0], cls.split(".").pop()]) {
            if (v.includes("/")) continue;
            const p = resolveIcon(v);
            if (p) return p;
        }
        return resolveIcon("application-x-executable");
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
                    fadeRestoreTimer.restart();
                    return;
                }
                root.readAgentPrograms(clients);
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
                root.originAddr = origin ? origin.address : "";
                root.originWs = activeWs;
                root.originMon = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.id : -1;
                root.shownWs = activeWs;
                root.open = true;
            }
        }
    }

    LazyLoader {
        active: root.open

        PanelWindow {
            id: panel

            // Hover only selects once the pointer really moved after the
            // overlay opened — the surface maps under a stationary cursor,
            // which must not steal the selection (GTK-version semantics).
            property bool hoverArmed: false
            property point initialPos: Qt.point(-1, -1)

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            WlrLayershell.namespace: "omarchy-alttab"
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            implicitWidth: content.implicitWidth
            implicitHeight: content.implicitHeight

            // Always focus the selection; only Escape cancels. Cancelling
            // when the pointer had left the overlay meant any cursor movement
            // (or a focus warp) silently dropped the chosen window.
            function activate() {
                root.close(true);
            }

            // Fast-tap race: modifier released before the exclusive keyboard
            // grant delivers any event. While no event has been seen, ask the
            // compositor for the real modifier state (the GDK query of the
            // Rust version); once an event arrives the key handlers own the
            // closing decision.
            Timer {
                id: noKeyTimer
                interval: 150
                repeat: true
                running: true
                onTriggered: {
                    if (root.sawKeyEvent) {
                        if (root.heldEmpty() && !root.modsHeld) panel.activate();
                        else stop();
                    } else {
                        modCheck.running = true;
                    }
                }
            }

            Process {
                id: modCheck
                command: ["hyprctl", "eval",
                    'error(tostring(hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R") or hl.is_key_down("Super_L") or hl.is_key_down("Super_R")))']
                stdout: StdioCollector {
                    onStreamFinished: {
                        if (!root.open || root.sawKeyEvent) return;
                        if (!text.trim().endsWith("true"))
                            panel.activate();
                    }
                }
            }

            Rectangle {
                id: content
                anchors.fill: parent
                color: Color.background
                border.color: Color.accent
                border.width: 2
                radius: 16
                implicitWidth: column.implicitWidth + 40
                implicitHeight: column.implicitHeight + 40

                focus: true

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                    onPositionChanged: (mouse) => {
                        if (panel.hoverArmed) return;
                        if (panel.initialPos.x < 0) {
                            panel.initialPos = Qt.point(mouse.x, mouse.y);
                            return;
                        }
                        if (Math.abs(mouse.x - panel.initialPos.x) + Math.abs(mouse.y - panel.initialPos.y) > 3)
                            panel.hoverArmed = true;
                    }
                }

                Keys.onPressed: (event) => {
                    root.sawKeyEvent = true;
                    root.modsHeld = !!(event.modifiers & (Qt.AltModifier | Qt.MetaModifier));
                    if (event.key === Qt.Key_Escape) {
                        root.close(false);
                        event.accepted = true;
                        return;
                    }
                    if (!root.isModifierKey(event.key))
                        root.heldKeys[event.key] = true;
                    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Right) {
                        root.next();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Left) {
                        root.prev();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        panel.activate();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_P && !event.isAutoRepeat) {
                        root.togglePreviews();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_F && !event.isAutoRepeat) {
                        root.toggleHighlight();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Q && !event.isAutoRepeat) {
                        root.closeSelected();
                        event.accepted = true;
                    }
                }

                Keys.onReleased: (event) => {
                    root.sawKeyEvent = true;
                    delete root.heldKeys[event.key];
                    // event.modifiers may still include the modifier being
                    // released — subtract it explicitly, like the Rust port.
                    const altReleasing = event.key === Qt.Key_Alt;
                    const superReleasing = event.key === Qt.Key_Meta
                        || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R;
                    const altHeld = (event.modifiers & Qt.AltModifier) && !altReleasing;
                    const superHeld = (event.modifiers & Qt.MetaModifier) && !superReleasing;
                    root.modsHeld = !!(altHeld || superHeld);
                    if (!root.modsHeld && (altReleasing || superReleasing || root.heldEmpty()))
                        panel.activate();
                }

                Column {
                    id: column
                    anchors.centerIn: parent
                    spacing: 0

                    // One long row of groups: with enough windows it is wider
                    // than the screen, and the selection could sit past either
                    // edge with nothing to show it. Cap it at the screen and
                    // scroll the selected frame into view.
                    Flickable {
                        id: strip
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(groupsRow.implicitWidth, panel.screen ? panel.screen.width - 120 : 1600)
                        height: groupsRow.implicitHeight
                        contentWidth: groupsRow.implicitWidth
                        contentHeight: height
                        clip: true
                        interactive: contentWidth > width
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.HorizontalFlick

                        // Leave a frame's worth of margin, so the neighbour in
                        // the scroll direction hints that there is more.
                        function reveal(x, w) {
                            if (contentWidth <= width)
                                return;
                            const margin = 48;
                            if (x - margin < contentX)
                                contentX = Math.max(0, x - margin);
                            else if (x + w + margin > contentX + width)
                                contentX = Math.min(contentWidth - width, x + w + margin - width);
                        }

                        Behavior on contentX {
                            NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
                        }

                    Row {
                        id: groupsRow
                        spacing: 0

                        Repeater {
                            model: root.groups

                            Row {
                                required property var modelData
                                required property int index
                                spacing: 0

                                Rectangle {
                                    visible: index > 0
                                    width: 1
                                    height: wsCol.height
                                    color: Qt.alpha(Color.foreground, 0.2)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    id: wsCol
                                    spacing: 4
                                    leftPadding: index > 0 ? 16 : 8
                                    rightPadding: 8

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: Logic.shortWorkspaceName(modelData.name)
                                        textFormat: Text.PlainText
                                        color: Qt.alpha(Color.foreground, 0.5)
                                        font.pixelSize: 11
                                        bottomPadding: 4
                                        // A name that is neither numbered nor
                                        // slotted can still be long; keep the end,
                                        // which is what tells two apart.
                                        width: Math.min(implicitWidth, 240)
                                        elide: Text.ElideLeft
                                        horizontalAlignment: Text.AlignHCenter
                                    }

                                    Row {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        spacing: 8

                                        Repeater {
                                            model: modelData.entries

                                            Rectangle {
                                                id: frame
                                                required property var modelData
                                                property bool isSelected: root.selected === modelData.flatIdx
                                                onIsSelectedChanged: if (isSelected) strip.reveal(frame.mapToItem(groupsRow, 0, 0).x, frame.width)
                                                readonly property var source: root.toplevelByAddr[modelData.addr.replace(/^0x/, "")] || null

                                                width: thumb.width + 24
                                                height: root.previews ? thumb.height + caption.height + 26 : thumb.height + 20
                                                radius: 12
                                                color: isSelected
                                                    ? Qt.alpha(Color.accent, frameHover.hovered ? 0.4 : 0.25)
                                                    : "transparent"
                                                opacity: modelData.hidden ? 0.75 : 1.0
                                                border.width: modelData.hidden ? 1 : 0
                                                border.color: Qt.alpha(Color.accent, 0.45)

                                                // Still frame of the window; the app icon stands in
                                                // until it arrives or when capture is unavailable.
                                                Rectangle {
                                                    id: thumb
                                                    x: 12
                                                    y: root.previews ? 12 : 10
                                                    width: root.previews ? Logic.tileWidth(frame.modelData, root.thumbHeight) : root.thumbHeight
                                                    height: root.thumbHeight
                                                    radius: 6
                                                    color: root.previews ? Qt.alpha(Color.foreground, 0.06) : "transparent"
                                                    clip: true

                                                    ScreencopyView {
                                                        id: capture
                                                        anchors.fill: parent
                                                        captureSource: root.open && root.previews ? frame.source : null
                                                        live: false
                                                        paintCursor: false
                                                        constraintSize: Qt.size(Math.max(1, width), Math.max(1, height))
                                                        visible: hasContent
                                                    }

                                                    Image {
                                                        id: icon
                                                        readonly property int size: capture.hasContent
                                                            ? Math.round(Math.min(32, root.thumbHeight * 0.3))
                                                            : root.previews ? Math.round(Math.min(64, root.thumbHeight * 0.55)) : 64
                                                        // Centered placeholder, then a corner badge over the preview.
                                                        x: capture.hasContent ? parent.width - size - 6 : (parent.width - size) / 2
                                                        y: capture.hasContent ? parent.height - size - 6 : (parent.height - size) / 2
                                                        width: size
                                                        height: size
                                                        sourceSize.width: 64
                                                        sourceSize.height: 64
                                                        source: root.iconPathFor(frame.modelData.cls, frame.modelData.title, frame.modelData.pid)
                                                        visible: source != "" && status !== Image.Error
                                                    }

                                                    Rectangle {
                                                        x: icon.x
                                                        y: icon.y
                                                        width: icon.size
                                                        height: icon.size
                                                        radius: icon.size / 4
                                                        visible: !icon.visible
                                                        color: Qt.alpha(Color.accent, 0.3)

                                                        Text {
                                                            anchors.centerIn: parent
                                                            text: (frame.modelData.cls || "?").charAt(0).toUpperCase()
                                                            textFormat: Text.PlainText
                                                            color: Color.foreground
                                                            font.pixelSize: Math.round(icon.size / 2)
                                                            font.bold: true
                                                        }
                                                    }
                                                }

                                                Rectangle {
                                                    visible: root.hasBadge(frame.modelData.addr)
                                                    x: thumb.x + thumb.width - width / 2 - 2
                                                    y: thumb.y - height / 2 + 2
                                                    width: 14
                                                    height: 14
                                                    radius: 7
                                                    color: "#e5484d"
                                                    border.width: 2
                                                    border.color: Color.background
                                                }

                                                Text {
                                                    id: caption
                                                    anchors.top: thumb.bottom
                                                    anchors.topMargin: 6
                                                    anchors.horizontalCenter: thumb.horizontalCenter
                                                    width: thumb.width
                                                    visible: root.previews
                                                    text: frame.modelData.title
                                                    textFormat: Text.PlainText
                                                    color: frame.isSelected ? Color.foreground : Qt.alpha(Color.foreground, 0.65)
                                                    font.pixelSize: 11
                                                    elide: Text.ElideRight
                                                    horizontalAlignment: Text.AlignHCenter
                                                    maximumLineCount: 1
                                                }

                                                property bool hoverSelect: frameHover.hovered && panel.hoverArmed
                                                onHoverSelectChanged: if (hoverSelect) root.selected = frame.modelData.flatIdx

                                                HoverHandler {
                                                    id: frameHover
                                                }

                                                TapHandler {
                                                    onTapped: {
                                                        root.selected = frame.modelData.flatIdx;
                                                        panel.activate();
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    }

                    // Fixed width/height so changing titles never resize the overlay.
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        topPadding: 10
                        width: Math.min(strip.width, 600)
                        height: topPadding + 22
                        maximumLineCount: 1
                        text: root.flat.length
                            ? root.flat[root.selected].cls + "  —  " + root.flat[root.selected].title
                            : ""
                        textFormat: Text.PlainText
                        color: Color.foreground
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
