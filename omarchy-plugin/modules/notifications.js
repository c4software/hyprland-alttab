// Pure logic of the notification badges — no Quickshell imports so it stays testable.
.pragma library

// Senders that never map to one window: Omarchy's own toasts, the notify-send
// CLI, and browsers, whose web apps all notify under the browser's name.
const IGNORED = ["omarchyaction", "notifysend", "googlechrome", "chromium", "firefox",
    "bravebrowser", "microsoftedge", "vivaldi", "zenbrowser"];

function normalize(s) {
    return String(s || "").toLowerCase().replace(/[^a-z0-9]/g, "");
}

// Same rule as omarchy-hyprland-focus-app (class contains the app name), on
// alphanumerics only so "Telegram Desktop" matches "org.telegram.desktop".
function appMatchesClass(app, cls) {
    const a = normalize(app), c = normalize(cls);
    if (a.length < 3 || c.length < 3) return false;
    return c.indexOf(a) >= 0 || a.indexOf(c) >= 0;
}

// One notification file per line; unreadable or partial lines are skipped.
function parseNotifications(text) {
    const out = [];
    for (const line of String(text || "").split("\n")) {
        let n = null;
        try { n = JSON.parse(line); } catch (e) { continue; }
        if (n && typeof n.app === "string" && n.app && typeof n.timestamp === "number")
            out.push({ app: n.app, timestamp: n.timestamp });
    }
    return out;
}

// Address -> true for windows with a notification newer than the last time
// their class was looked at (lastSeen: lowercase class -> ms, since: default).
// Each notification badges the most recently used matching window.
function unreadAddrs(notifications, flat, lastSeen, since) {
    const unread = {};
    for (const n of notifications) {
        if (IGNORED.indexOf(normalize(n.app)) >= 0) continue;
        let best = null;
        for (const e of flat) {
            if (!appMatchesClass(n.app, e.cls)) continue;
            if (n.timestamp <= (lastSeen[String(e.cls).toLowerCase()] || since)) continue;
            if (!best || e.fhid < best.fhid) best = e;
        }
        if (best) unread[best.addr] = true;
    }
    return unread;
}
