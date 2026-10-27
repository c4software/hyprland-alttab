// Pure logic shared by shell.qml — no Quickshell imports so it stays testable.
.pragma library

function defaultTheme() {
    return { background: "#2c2525", border: "#f38d70", text: "#e6d9db" };
}

// Parse Omarchy colors.toml: background / accent / foreground, last occurrence wins.
function parseTheme(text) {
    const theme = defaultTheme();
    if (!text) return theme;
    for (const line of text.split("\n")) {
        const eq = line.indexOf("=");
        if (eq < 0) continue;
        const key = line.slice(0, eq).trim();
        const value = line.slice(eq + 1).trim().replace(/^"|"$/g, "");
        if (!value) continue;
        if (key === "background") theme.background = value;
        else if (key === "accent") theme.border = value;
        else if (key === "foreground") theme.text = value;
    }
    return theme;
}

// Optional modules (modules/<file>) and whether they load by default.
function moduleList() {
    return [
        { id: "notificationBadges", file: "NotificationBadges.qml", enabled: true },
    ];
}

function defaultModules() {
    const m = {};
    for (const mod of moduleList()) m[mod.id] = mod.enabled;
    return m;
}

// Parse ~/.config/omarchy/alttab.json; missing or invalid keys keep defaults.
function parseConfig(text) {
    const config = { previews: true, modules: defaultModules() };
    let data = null;
    try { data = JSON.parse(text); } catch (e) { return config; }
    if (data && typeof data.previews === "boolean") config.previews = data.previews;
    if (data && data.modules && typeof data.modules === "object")
        for (const id in config.modules)
            if (typeof data.modules[id] === "boolean") config.modules[id] = data.modules[id];
    return config;
}

// Workspace names are free-form. Plugins that give every monitor its own set
// (per-monitor-workspaces, for one) name them "<monitor description>:<slot>",
// e.g. "LG Electronics LG ULTRAFINE 508NTHMJJ505:2" — a group header several
// times wider than the windows under it. Keep the trailing slot for those.
// Omarchy numbers workspaces in blocks of ten per monitor (11-20, 31-40…) and
// shows the slot 1-10, as its bar does. Other names are returned unchanged.
function shortWorkspaceName(name) {
    const text = String(name === null || name === undefined ? "" : name);
    if (text.indexOf("special:") === 0) return text;
    const match = text.match(/^.+:(\d+)$/);
    if (match) return match[1];
    if (/^\d+$/.test(text) && Number(text) > 0) return String((Number(text) - 1) % 10 + 1);
    return text;
}

// Group clients by workspace: active workspace first then ascending id;
// within a group the focused window (fhid == 0) first, then ascending fhid.
// Pinned windows excluded, empty titles replaced with "-".
// groupIdx: 1-based position in the client's Hyprland group, 0 if ungrouped.
// w/h: window size, used for the preview aspect ratio.
// Returns [{ name, entries: [{ cls, title, addr, hidden, fhid, flatIdx, groupIdx, w, h }] }].
function groupClients(clients, activeWsId) {
    const wsOrder = [];
    const wsMap = {};

    for (const c of clients) {
        if (c.pinned) continue;
        const wsId = c.workspace.id;
        if (!(wsId in wsMap)) {
            wsOrder.push(wsId);
            wsMap[wsId] = { name: c.workspace.name, clients: [] };
        }
        wsMap[wsId].clients.push(c);
    }

    wsOrder.sort((a, b) => {
        const pa = a === activeWsId ? 0 : 1;
        const pb = b === activeWsId ? 0 : 1;
        return pa !== pb ? pa - pb : a - b;
    });

    let flatIdx = 0;
    const groups = [];
    for (const wsId of wsOrder) {
        const ws = wsMap[wsId];
        ws.clients.sort((a, b) => {
            const ka = a.focusHistoryID === 0 ? -1 : a.focusHistoryID;
            const kb = b.focusHistoryID === 0 ? -1 : b.focusHistoryID;
            return ka - kb;
        });
        groups.push({
            name: ws.name,
            entries: ws.clients.map(c => ({
                cls: c.class,
                title: c.title || "-",
                addr: c.address,
                hidden: !!c.hidden,
                fhid: c.focusHistoryID,
                flatIdx: flatIdx++,
                groupIdx: c.grouped ? c.grouped.indexOf(c.address) + 1 : 0,
                w: c.size ? c.size[0] : 0,
                h: c.size ? c.size[1] : 0,
            })),
        });
    }
    return groups;
}

function flatten(groups) {
    const flat = [];
    for (const g of groups)
        for (const e of g.entries)
            flat.push(e);
    return flat;
}

// Groups without the window at addr; empty groups dropped, flatIdx renumbered.
function removeEntry(groups, addr) {
    let flatIdx = 0;
    const out = [];
    for (const g of groups) {
        const entries = g.entries
            .filter(e => e.addr !== addr)
            .map(e => Object.assign({}, e, { flatIdx: flatIdx++ }));
        if (entries.length) out.push({ name: g.name, entries: entries });
    }
    return out;
}

// Second-most-recently-used window: smallest fhid > 0, fallback 0.
function initialSelection(flat) {
    let best = -1, bestFhid = Infinity;
    for (let i = 0; i < flat.length; i++) {
        if (flat[i].fhid > 0 && flat[i].fhid < bestFhid) {
            bestFhid = flat[i].fhid;
            best = i;
        }
    }
    return best >= 0 ? best : 0;
}

// Preview width for a window at the given thumbnail height, clamped so very
// wide or very tall windows keep a readable tile.
function tileWidth(entry, thumbH) {
    const aspect = entry.w > 0 && entry.h > 0 ? entry.w / entry.h : 16 / 10;
    return Math.round(Math.max(0.6, Math.min(2.4, aspect)) * thumbH);
}

// Largest thumbnail height (capped at maxH) whose row still fits availW.
function fitThumbHeight(flat, groupCount, maxH, availW) {
    const fixed = flat.length * (24 + 8) + groupCount * 25 + 40;
    let unit = 0;
    for (const e of flat) unit += tileWidth(e, 1000) / 1000;
    if (unit <= 0) return maxH;
    return Math.max(56, Math.min(maxH, Math.floor((availW - fixed) / unit)));
}
