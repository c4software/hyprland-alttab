import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons

// While the switcher is open: selected window tagged "alttab-selected", the others
// "alttab-dim" (window rules style them), and the shown workspace follows the selection.
Item {
    id: root

    required property var service
    property bool enabled: false
    property int fadeOpacity: 80
    property int fadeDuration: 250

    readonly property bool open: service.open
    property string highlightedAddr: ""
    property var dimmedAddrs: ({})
    readonly property string target: open && enabled && service.flat[service.selected] ? service.flat[service.selected].addr : ""
    onTargetChanged: update()
    onEnabledChanged: {
        if (open && enabled) prepare();
        update();
    }

    Connections {
        target: root.service
        function onFlatChanged() { root.update(); }
        function onOpenChanged() {
            root.followReady = false;
            if (root.open) followTimer.restart();
            else fadeRestoreTimer.restart();
        }
    }

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
        const entry = open && followReady ? service.flat[service.selected] : null;
        if (!entry || entry.ws <= 0 || entry.ws === shownWs || entry.mon !== originMon) return;
        Hyprland.dispatch('hl.dsp.focus({ workspace = "' + entry.ws + '" })');
        shownWs = entry.ws;
    }

    function update() {
        const batch = [];
        const moved = target !== highlightedAddr;
        if (moved) {
            if (highlightedAddr) batch.push(tagStatement(highlightedAddr, "-alttab-selected"));
            if (target) batch.push(tagStatement(target, "+alttab-selected"));
            highlightedAddr = target;
        }
        const wanted = {};
        if (open && enabled)
            for (const e of service.flat)
                if (e.addr !== target) wanted[e.addr] = true;
        for (const a in dimmedAddrs)
            if (!wanted[a]) batch.push(tagStatement(a, "-alttab-dim"));
        for (const a in wanted)
            if (!dimmedAddrs[a]) batch.push(tagStatement(a, "+alttab-dim"));
        dimmedAddrs = wanted;
        hyprBatch(batch);
        if (moved) followWorkspace();
    }

    // Called before the switcher opens.
    function beforeOpen() {
        fadeRestoreTimer.stop();
        if (!fadeSwitchKnown && !fadeSwitchRead.running) fadeSwitchRead.running = true;
        if (enabled) prepare();
    }

    // Called when an opening is dropped (no window to list).
    function openCancelled() {
        fadeRestoreTimer.restart();
    }

    function opened(originAddress, workspaceId, monitorId) {
        originAddr = originAddress;
        originWs = workspaceId;
        originMon = monitorId;
        shownWs = workspaceId;
    }

    function windowClosed(addr) {
        if (addr === originAddr) originAddr = "";
    }

    // Where Escape returns: null when the shown workspace never changed.
    function returnTarget() {
        return shownWs === originWs ? null : { addr: originAddr, ws: originWs };
    }

    readonly property string accentHex: {
        const hex = String(Color.accent).replace("#", "").slice(-6);
        return /^[0-9a-fA-F]{6}$/.test(hex) ? hex : "ffffff";
    }

    // Rules are redefined on each opening: a dispatch sent while the shell starts is lost.
    function prepare() {
        defineRules();
        setFadeSwitch(true);
    }

    function defineRules() {
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
                if (root.open && root.enabled) root.setFadeSwitch(true);
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
}
