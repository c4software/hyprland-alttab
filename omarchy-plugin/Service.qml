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

    // The overlay takes no keyboard focus: Hyprland refuses window focus while
    // an exclusive layer holds the keyboard, and focus follows the selection.
    // The keys live in the "alttab" submap from alttab-bindings.lua instead,
    // active while the switcher is open.
    onOpenChanged: {
        submapEntered = false;
        Hyprland.dispatch('hl.dsp.submap("' + (open ? "alttab" : "reset") + '")');
        shown = false;
        if (open) revealTimer.restart();
    }

    // Escape resets the submap from Hyprland itself, so it still works if the
    // shell dies mid-switch; the reset is the cancel signal. The reset of a
    // previous close can arrive after a quick reopen: only a reset after the
    // submap was entered counts.
    property bool submapEntered: false

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "submap" || !root.open) return;
            if (event.data === "alttab") root.submapEntered = true;
            else if (root.submapEntered) root.close(false);
        }
        function onActiveToplevelChanged() {
            if (root.open || focusTimer.running || !Hyprland.activeToplevel) return;
            root.history = Logic.noteFocus(root.history, Hyprland.activeToplevel.address);
        }
    }

    // The overlay appears only once the modifier has been held this long, so
    // a quick tap switches windows without flashing it.
    readonly property int revealDelay: 350
    property bool shown: false

    Timer {
        id: revealTimer
        interval: root.revealDelay
        onTriggered: root.shown = root.open
    }

    // Fast-tap race: the modifier can be released before the submap is
    // active, so its release bind never fires. Poll the compositor for the
    // real modifier state (the GDK query of the Rust version); this also
    // closes the switcher if a release bind is ever missed.
    Timer {
        interval: 150
        repeat: true
        running: root.open
        onTriggered: modCheck.running = true
    }

    Process {
        id: modCheck
        command: ["hyprctl", "eval",
            'error(tostring(hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R") or hl.is_key_down("Super_L") or hl.is_key_down("Super_R")))']
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.open && !text.trim().endsWith("true"))
                    root.close(true);
            }
        }
    }

    // The switcher's own focus history (address keys, most recent first).
    // Focus changes while it is open or committing are not recorded, so the
    // windows passed while browsing do not count as recently used.
    property var history: []

    property var groups: []
    property var flat: []
    property int selected: 0

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
        onLoaded: {
            const config = Logic.parseConfig(text());
            root.previews = config.previews;
            root.modules = config.modules;
        }
        onFileChanged: reload()
        onLoadFailed: {
            root.previews = true;
            root.modules = Logic.defaultModules();
        }
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

    // Switch between previews and icons, persisted to alttab.json.
    function togglePreviews() {
        let data = {};
        try { data = JSON.parse(configFile.text()) || {}; } catch (e) {}
        root.previews = !root.previews;
        data.previews = root.previews;
        configFile.setText(JSON.stringify(data, null, 2) + "\n");
        if (root.previews) Hyprland.refreshToplevels();
        root.fitThumbs(root.flat, root.groups.length);
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
        root.liveFocus();
    }

    function refreshToplevels() {
        const map = {};
        for (const t of Hyprland.toplevels.values)
            if (t && t.wayland) map[String(t.address).replace(/^0x/, "")] = t.wayland;
        toplevelByAddr = map;
    }

    function next() { if (flat.length) { selected = (selected + 1) % flat.length; liveFocus(); } }
    function prev() { if (flat.length) { selected = (selected + flat.length - 1) % flat.length; liveFocus(); } }

    property bool pendingReverseOpen: false

    function requestOpen(reverse) {
        root.pendingReverseOpen = !!reverse;
        if (root.previews) Hyprland.refreshToplevels();
        if (root.shell && root.shell.appLibrary) root.shell.appLibrary.refreshIcons();
        clientsProc.running = true;
    }

    // The window that was focused when the switcher opened. Escape returns to it.
    property string originAddr: ""
    property int originGroupIdx: 0

    // hl.dsp.focus silently ignores hidden group tabs (Hyprland ≥0.56), so
    // switch the group's active tab first. Two dispatches: the payload is
    // evaluated as a single Lua expression. Focus does not raise floating windows.
    function focusWindow(addr, groupIdx) {
        if (groupIdx)
            Hyprland.dispatch('hl.dsp.group.active({ window = "address:' + addr + '", index = ' + groupIdx + ' })');
        Hyprland.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })');
        Hyprland.dispatch('hl.dsp.window.bring_to_top()');
    }

    // Focus follows the selection while the modifier is held.
    function liveFocus() {
        if (open && flat.length)
            focusWindow(flat[selected].addr, flat[selected].groupIdx);
    }

    // doFocus=false: Escape semantics — return to the window that was focused
    // when the switcher opened.
    function close(doFocus) {
        if (!open) return;
        const entry = (doFocus && flat.length) ? flat[selected] : null;
        open = false;
        pendingAddr = entry ? entry.addr : originAddr;
        pendingGroupIdx = entry ? entry.groupIdx : originGroupIdx;
        if (!pendingAddr) return;
        focusTimer.start();
    }

    property string pendingAddr: ""
    property int pendingGroupIdx: 0

    // Dispatch after the overlay surface is gone, so its teardown cannot move
    // focus afterwards. The chosen window is usually focused already (live
    // focus), which fires no focus change: record it in the history here.
    Timer {
        id: focusTimer
        interval: 100
        onTriggered: {
            root.focusWindow(root.pendingAddr, root.pendingGroupIdx);
            root.history = Logic.noteFocus(root.history, root.pendingAddr);
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
    // Chrome web app URL from Exec → app Name as whole word in title (longest
    // wins) → icon theme variants → generic.
    function iconPathFor(cls, title) {
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

    // One shortcut serves ALT+Tab and SUPER+Tab, outside the submap to open
    // and inside it to advance.
    GlobalShortcut {
        appid: "omarchy-alttab"
        name: "next"
        onPressed: root.open ? root.next() : root.requestOpen()
    }

    // Mirrors "next" for the reverse direction (e.g. ALT+SHIFT+TAB); a cold
    // press opens the overlay on the last window of the list.
    GlobalShortcut {
        appid: "omarchy-alttab"
        name: "prev"
        onPressed: root.open ? root.prev() : root.requestOpen(true)
    }

    // Keys of the "alttab" submap, bound only while the switcher is open.
    GlobalShortcut { appid: "omarchy-alttab"; name: "commit"; onPressed: root.close(true) }
    GlobalShortcut { appid: "omarchy-alttab"; name: "toggle-previews"; onPressed: if (root.open) root.togglePreviews() }
    GlobalShortcut { appid: "omarchy-alttab"; name: "close-selected"; onPressed: if (root.open) root.closeSelected() }

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
                // The window Hyprland has focused is the most recent one.
                const origin = clients.find(c => c.focusHistoryID === 0);
                if (origin) root.history = Logic.noteFocus(root.history, origin.address);
                clients = Logic.applyHistory(clients, root.history);
                const activeWs = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
                const groups = Logic.groupClients(clients, activeWs);
                const flat = Logic.flatten(groups);
                if (!flat.length) return;
                root.fitThumbs(flat, groups.length);
                root.refreshModules(flat);
                root.originAddr = origin ? origin.address : "";
                root.originGroupIdx = origin && origin.grouped
                    ? origin.grouped.indexOf(origin.address) + 1 : 0;
                root.groups = groups;
                root.flat = flat;
                root.selected = root.pendingReverseOpen ? flat.length - 1 : Logic.initialSelection(flat);
                root.pendingReverseOpen = false;
                root.open = true;
                root.liveFocus();
            }
        }
    }

    LazyLoader {
        active: root.open && root.shown

        PanelWindow {
            id: panel

            // Hover only selects once the pointer really moved after the
            // overlay opened — the surface maps under a stationary cursor,
            // which must not steal the selection (GTK-version semantics).
            property bool hoverArmed: false
            property point initialPos: Qt.point(-1, -1)

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.namespace: "omarchy-alttab"
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            implicitWidth: content.implicitWidth
            implicitHeight: content.implicitHeight

            Rectangle {
                id: content
                anchors.fill: parent
                color: Color.background
                border.color: Color.accent
                border.width: 2
                radius: 16
                implicitWidth: column.implicitWidth + 40
                implicitHeight: column.implicitHeight + 40

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
                                                        source: root.iconPathFor(frame.modelData.cls, frame.modelData.title)
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
                                                        root.close(true);
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
