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

    function requestOpen() {
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
    // evaluated as a single Lua expression.
    Timer {
        id: focusTimer
        interval: 100
        onTriggered: {
            if (root.pendingGroupIdx)
                Hyprland.dispatch('hl.dsp.group.active({ window = "address:' + root.pendingAddr + '", index = ' + root.pendingGroupIdx + ' })');
            Hyprland.dispatch('hl.dsp.focus({ window = "address:' + root.pendingAddr + '" })');
        }
    }

    // Icon cascade: desktop entry by id variants → StartupWMClass scan →
    // app Name substring-of-title scan (Chrome PWAs) → icon theme variants → generic.
    function iconPathFor(cls, title) {
        const clsLower = cls.toLowerCase();
        for (const v of [cls, clsLower, cls.replace(/-/g, ""), cls.split(".")[0]]) {
            if (!v) continue;
            const e = DesktopEntries.byId(v);
            if (e && e.icon) return Quickshell.iconPath(e.icon, "application-x-executable");
        }
        const all = DesktopEntries.applications.values;
        for (const e of all) {
            if (e.startupClass && e.startupClass.toLowerCase() === clsLower && e.icon)
                return Quickshell.iconPath(e.icon, "application-x-executable");
        }
        const titleLower = (title || "").toLowerCase();
        if (titleLower) {
            for (const e of all) {
                const n = (e.name || "").toLowerCase();
                if (n && titleLower.includes(n) && e.icon)
                    return Quickshell.iconPath(e.icon, "application-x-executable");
            }
        }
        for (const v of [cls, clsLower, cls.split("-")[0], cls.split(".").pop()]) {
            if (!v) continue;
            const p = Quickshell.iconPath(v, true);
            if (p) return p;
        }
        return Quickshell.iconPath("application-x-executable");
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

                    Row {
                        id: groupsRow
                        anchors.horizontalCenter: parent.horizontalCenter
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
                                        text: modelData.name
                                        color: Qt.alpha(Color.foreground, 0.5)
                                        font.pixelSize: 11
                                        bottomPadding: 4
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

                    // Fixed width/height so changing titles never resize the overlay.
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        topPadding: 10
                        width: Math.min(groupsRow.width, 600)
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
