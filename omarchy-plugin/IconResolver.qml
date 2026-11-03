import QtQuick
import Quickshell
import Quickshell.Io
import "logic.js" as Logic

// Icon of a window: desktop entries, Chrome web apps, Omarchy terminal apps and agents.
Item {
    id: root

    property var shell: null

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
}
