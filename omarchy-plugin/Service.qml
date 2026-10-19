import QtQuick
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
    property var groups: []
    property var flat: []
    property int selected: 0

    // Keyboard state observed by the overlay. The initial ALT press predates
    // the surface, so modifier state is only known from received events.
    property var heldKeys: ({})
    property bool sawKeyEvent: false
    property bool modsHeld: false

    function heldEmpty() {
        for (const k in heldKeys) return false;
        return true;
    }

    function next() { if (flat.length) selected = (selected + 1) % flat.length }
    function prev() { if (flat.length) selected = (selected + flat.length - 1) % flat.length }

    property bool pendingReverseOpen: false

    function requestOpen(reverse) {
        root.pendingReverseOpen = !!reverse;
        clientsProc.running = true;
    }

    // doFocus=false: Escape / pointer-left semantics — close without focusing.
    function close(doFocus) {
        if (!open) return;
        const entry = (doFocus && flat.length) ? flat[selected] : null;
        open = false;
        if (!entry) return;
        pendingAddr = entry.addr;
        pendingGroupIdx = entry.groupIdx;
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
            if (root.pendingGroupIdx)
                Hyprland.dispatch('hl.dsp.group.active({ window = "address:' + root.pendingAddr + '", index = ' + root.pendingGroupIdx + ' })');
            Hyprland.dispatch('hl.dsp.focus({ window = "address:' + root.pendingAddr + '" })');
            Hyprland.dispatch('hl.dsp.window.bring_to_top()');
        }
    }

    // Icon cascade: desktop entry by id variants → StartupWMClass scan →
    // app Name substring-of-title scan (Chrome PWAs) → icon theme variants → generic.
    // Returns "" when nothing resolves (e.g. the configured icon theme is missing).
    function resolveIcon(name) {
        if (!name) return "";
        if (name.startsWith("/")) return "file://" + name;
        return Quickshell.iconPath(name, true);
    }

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
        const titleLower = (title || "").toLowerCase();
        if (titleLower) {
            for (const e of all) {
                const n = (e.name || "").toLowerCase();
                if (n && titleLower.includes(n)) {
                    const p = resolveIcon(e.icon);
                    if (p) return p;
                }
            }
        }
        for (const v of [cls, clsLower, cls.split("-")[0], cls.split(".").pop()]) {
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

    // Mirrors "next" for the reverse direction (e.g. ALT+SHIFT+TAB), so a cold
    // press opens the overlay already stepped one back instead of forward.
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
                if (!flat.length) return;
                root.groups = groups;
                root.flat = flat;
                root.selected = Logic.initialSelection(flat);
                if (root.pendingReverseOpen) root.prev();
                root.pendingReverseOpen = false;
                root.heldKeys = {};
                root.sawKeyEvent = false;
                root.modsHeld = false;
                root.open = true;
            }
        }
    }

    LazyLoader {
        active: root.open

        PanelWindow {
            id: panel

            property bool mouseInside: true
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

            function activate() {
                root.close(mouseInside);
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
                    if (root.heldEmpty() && !root.modsHeld)
                        panel.activate();
                }

                HoverHandler {
                    onHoveredChanged: panel.mouseInside = hovered
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

                                                width: icon.width + 24
                                                height: icon.height + 20
                                                radius: 12
                                                color: isSelected
                                                    ? Qt.alpha(Color.accent, frameHover.hovered ? 0.4 : 0.25)
                                                    : "transparent"
                                                opacity: modelData.hidden ? 0.75 : 1.0
                                                border.width: modelData.hidden ? 1 : 0
                                                border.color: Qt.alpha(Color.accent, 0.45)

                                                Image {
                                                    id: icon
                                                    anchors.centerIn: parent
                                                    width: 64
                                                    height: 64
                                                    sourceSize.width: 64
                                                    sourceSize.height: 64
                                                    source: root.iconPathFor(frame.modelData.cls, frame.modelData.title)
                                                    visible: source != "" && status !== Image.Error
                                                }

                                                Rectangle {
                                                    anchors.centerIn: parent
                                                    width: 56
                                                    height: 56
                                                    radius: 14
                                                    visible: !icon.visible
                                                    color: Qt.alpha(Color.accent, 0.3)

                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: (frame.modelData.cls || "?").charAt(0).toUpperCase()
                                                        color: Color.foreground
                                                        font.pixelSize: 28
                                                        font.bold: true
                                                    }
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
