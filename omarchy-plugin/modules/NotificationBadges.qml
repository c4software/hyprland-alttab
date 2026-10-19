import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "notifications.js" as Notifications

// Unread-notification badges, read from the files omarchy-shell's notification
// service keeps (on-screen toasts and history). Loaded only when enabled.
Item {
    id: module

    // Address -> true for the windows to badge, recomputed by refresh().
    property var badges: ({})

    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/notifications"
    readonly property real since: Date.now()
    property var lastSeen: ({})
    property string activeClass: ""
    property var pendingFlat: []

    // A class counts as seen both when it gains and when it loses focus.
    function markSeen(cls) {
        if (cls) lastSeen[cls.toLowerCase()] = Date.now();
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "activewindow") return;
            const data = String(event.data);
            const comma = data.indexOf(",");
            module.markSeen(module.activeClass);
            module.activeClass = comma >= 0 ? data.slice(0, comma) : data;
            module.markSeen(module.activeClass);
        }
    }

    function refresh(flat) {
        markSeen(activeClass);
        pendingFlat = flat;
        reader.running = true;
    }

    Process {
        id: reader
        command: ["sh", "-c",
            'find "$1" -maxdepth 2 -name "*.json" -exec sh -c \'for f; do cat "$f"; echo; done\' sh {} + 2>/dev/null',
            "sh", module.stateDir]
        stdout: StdioCollector {
            onStreamFinished: module.badges = Notifications.unreadAddrs(
                Notifications.parseNotifications(text), module.pendingFlat, module.lastSeen, module.since)
        }
    }
}
