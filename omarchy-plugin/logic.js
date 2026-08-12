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

// Group clients by workspace: active workspace first then ascending id;
// within a group the focused window (fhid == 0) first, then ascending fhid.
// Pinned windows excluded, empty titles replaced with "-".
// Returns [{ name, entries: [{ cls, title, addr, hidden, fhid, flatIdx }] }].
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
