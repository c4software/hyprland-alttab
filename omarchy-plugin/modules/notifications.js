// Pure logic of the notification badges — no Quickshell imports so it stays testable.
.pragma library

// Senders that never map to one window: Omarchy's own toasts and the notify-send CLI.
const IGNORED = ["omarchyaction", "notifysend"];

// Browsers notify under their own name; Chromium-based ones prefix the body
// with the site's origin, matched against the web app window instead.
const BROWSERS = ["googlechrome", "chromium", "firefox", "bravebrowser", "microsoftedge",
    "vivaldi", "zenbrowser"];

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
            out.push({ app: n.app, body: typeof n.body === "string" ? n.body : "", timestamp: n.timestamp });
    }
    return out;
}

// Site host Chromium puts first in the body, as a link or as plain text.
function originHost(body) {
    const text = String(body || "");
    const link = /^\s*<a href="https?:\/\/([^\/"]+)/.exec(text);
    if (link) return link[1].toLowerCase();
    const first = text.split("\n\n")[0].trim();
    return /^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?$/i.test(first) ? first.toLowerCase() : "";
}

// Web app windows are named after their URL, e.g. chrome-web.whatsapp.com__-Default.
function hostMatchesClass(host, cls) {
    const h = normalize(host);
    return h.length >= 4 && normalize(cls).indexOf(h) >= 0;
}

// Address -> true for windows with a notification newer than the last time
// their class was looked at (lastSeen: lowercase class -> ms, since: default).
// Each notification badges the most recently used matching window.
function unreadAddrs(notifications, flat, lastSeen, since) {
    const unread = {};
    for (const n of notifications) {
        const app = normalize(n.app);
        if (IGNORED.indexOf(app) >= 0) continue;
        const host = BROWSERS.indexOf(app) >= 0 ? originHost(n.body) : null;
        if (host === "") continue;
        let best = null;
        for (const e of flat) {
            if (host ? !hostMatchesClass(host, e.cls) : !appMatchesClass(n.app, e.cls)) continue;
            if (n.timestamp <= (lastSeen[String(e.cls).toLowerCase()] || since)) continue;
            if (!best || e.fhid < best.fhid) best = e;
        }
        if (best) unread[best.addr] = true;
    }
    return unread;
}
