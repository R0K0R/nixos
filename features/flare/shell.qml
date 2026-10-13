//@ pragma UseQApplication
// Bonfire notification centre (quickshell) -- replaces swaync. A SIZED layer (namespace
// "flare") that the compositor keystone warps into a dock-card trapezoid.
//
// DESIGN: matches the shell's monochrome vibe (features/bonfire). Pure white-on-near-black;
// the accent is read live from ~/.local/state/glow/colors.css (the same token the whole
// shell uses -- @accent_color, currently #ffffff). ACTIVE controls INVERT (accent bg, black text),
// exactly like the waybar workspace chips. Font: DepartureMono Nerd Font, like the rest of the shell.
//
// Widgets: wifi · BT · DND · nosleep · nightmode · battery-mode(eco/bal/perf) · power · volume ·
// brightness · music · notifications.
//
// IPC:  quickshell -c flare ipc call panel toggle|show|hide
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Bluetooth
import Quickshell.Services.Notifications
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root

    property bool panelOpen: false
    property bool dnd: false
    property bool wifiOn: true
    property bool nightOn: false
    property bool nosleepOn: false
    property string powerProfile: "balanced"
    property bool recOn: false          // screen recording (wf-recorder) active?

    // Mutual exclusion via the panelbus (features/panelbus): opening THIS centre broadcasts, which
    // closes the dock + any pins. Only on open (closing shouldn't reopen anything). run() detaches it.
    onPanelOpenChanged: { if (panelOpen) { run("panelbus open flare"); pWeather.running = true; } else if (btMenu.adapter) btMenu.adapter.discovering = false; }

    // --- design tokens (monochrome, live accent; some live from hearth -- see hsGet below) ---
    property string ff: root.hsGet("panel.font.family", "DepartureMono Nerd Font")
    property string accent: "#ffffff"              // read from the theme below
    readonly property string fg: accent
    property string dim: root.hsGet("panel.colors.dim", "#80ffffff")              // secondary text (live)
    property string bgPanel: root.hsGet("panel.colors.background", "#e6000000")    // ~90% black (live): blur rule frosts
                                                    // the desktop behind it (0.9 was too opaque to show)
    property string bgTile: root.hsGet("panel.colors.tile", "#16ffffff")         // inactive tile (live)
    property string bgTileHi: root.hsGet("panel.colors.tile_hover", "#24ffffff") // hover (live)
    readonly property string invFg: "#000000"   // text/icon ON an active (accent) tile

    // ----- hearth live settings (features/settings generates the schema; hearth materialises
    // ~/.local/state/hearth/settings.json + signals changes). Read the whole store into `hs` and
    // re-read on any `panel.*` change, so tweaks apply live (e.g. `hearth set panel.width 900`). -----
    property var hs: ({})
    function hsGet(path, fallback) {
        var o = root.hs, parts = path.split(".");
        for (var i = 0; i < parts.length; i++) { if (o === null || o === undefined) return fallback; o = o[parts[i]]; }
        return (o === undefined || o === null) ? fallback : o;
    }
    // Read settings.json directly + watch it -- no `hearth` binary needed for reads, and a change to
    // any value reloads it, so bindings through hsGet() re-evaluate live.
    FileView {
        id: hsFile
        path: (Quickshell.env("HOME") || "/home/benjamin") + "/.local/state/hearth/settings.json"
        preload: true
        watchChanges: true
        onLoaded: { try { var o = JSON.parse(text()); if (o && o.panel !== undefined) root.hs = o; } catch (e) {} }
        onFileChanged: reload()
    }

    // ----- notification DAEMON -----
    NotificationServer {
        id: server
        keepOnReload: false
        bodySupported: true
        bodyMarkupSupported: true
        actionsSupported: true
        imageSupported: true
        onNotification: function (n) { n.tracked = true; if (!root.dnd) popups.add(n); }
    }

    PwObjectTracker { objects: Pipewire.nodes.values }   // track all audio nodes so per-app/device volumes stay live
    // audio mixer sources, live via the Pipewire service
    property var audioSinks: (Pipewire.nodes && Pipewire.nodes.values) ? Pipewire.nodes.values.filter(function (n) { return n && n.audio && n.isSink && !n.isStream; }) : []
    property var audioApps:  (Pipewire.nodes && Pipewire.nodes.values) ? Pipewire.nodes.values.filter(function (n) { return n && n.audio && n.isStream && n.isSink; }) : []
    function nodeName(n) {
        if (!n) return "?";
        var s = (n.properties && n.properties["application.name"]) || n.description || n.name || "?";
        var m = s.match(/\[\.?([^\]]+)\]/);                        // "PipeWire ALSA [.sonora-wrapped]" -> inside the brackets
        if (m) s = m[1].replace(/-wrapped$/, "").replace(/^\./, "");
        s = s.replace(/ Analog Stereo$/i, "").replace(/ Audio\/Sink sink$/i, "").replace(/_/g, " ").trim();
        return s.length ? s.charAt(0).toUpperCase() + s.slice(1) : (n.name || "?");
    }

    // ----- lyre engine state (headless per-app/per-output EQ + routing; driven over the `lyre` CLI) -----
    // bfStatus holds live values (active outputs + per-target EQ gains); bfAppList/bfDevList are the
    // Repeater models, updated ONLY when the app/device SET changes, so delegates (and an open Advanced
    // EQ) don't churn on every 2s status poll.
    property var bfStatus: ({ lyre: false, outputs: [], devices: [], apps: [], out_eq: ({}), app_eq: ({}) })
    property var bfAppList: []
    property var bfDevList: []
    property string _bfAppsKey: ""
    property string _bfDevKey: ""
    Process {
        id: pLyre
        command: ["sh","-c","lyre report 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: {
            try {
                var o = JSON.parse(text);
                if (!o || !o.devices) return;
                root.bfStatus = o;
                var ak = (o.apps || []).join("");
                if (ak !== root._bfAppsKey) { root._bfAppsKey = ak; root.bfAppList = o.apps || []; }
                var dk = (o.devices || []).map(function (d) { return d.name; }).join("");
                if (dk !== root._bfDevKey) { root._bfDevKey = dk; root.bfDevList = o.devices || []; }
            } catch (e) {}
        } }
    }
    function bfRefresh() { pLyre.running = true; }
    readonly property var bfBandLabels: ["31","62","125","250","500","1k","2k","4k","8k","16k"]
    readonly property var bfPresets: [
        { name: "Flat",   g: [0,0,0,0,0,0,0,0,0,0] },
        { name: "Bass",   g: [6,5,4,2,0,0,0,0,0,0] },
        { name: "Vocal",  g: [-3,-2,-1,1,3,3,2,0,-1,-2] },
        { name: "Treble", g: [0,0,0,0,0,1,2,4,5,5] },
        { name: "Loud",   g: [5,4,2,0,-1,-1,0,2,4,6] }
    ]
    function bfGains(scope, target) {
        var m = (scope === "out") ? root.bfStatus.out_eq : root.bfStatus.app_eq;
        var g = (m && m[target]) ? m[target] : null;
        return g ? g.slice() : [0,0,0,0,0,0,0,0,0,0];
    }
    // lyre's app key for a Pipewire node -- MUST mirror clean_app_name() in lyre/main.py so the
    // `eq app <key>` target matches the stream lyre moves through the per-app chain.
    function bfAppKey(n) {
        if (!n) return "Audio";
        var pl = n.properties || {};
        var raw = pl["application.name"] || "";
        var m = raw.match(/\[([^\]]+)\]/);
        var name = (m ? m[1] : raw).replace(/^[ .]+/, "").replace(/[ .]+$/, "");
        name = name.replace(/[-_]?wrapped$/, "");
        if (!name) name = pl["media.name"] || n.name || "Audio";
        if (name && name === name.toLowerCase())
            name = name.replace(/-/g, " ").replace(/_/g, " ").trim()
                       .replace(/\b\w/g, function (c) { return c.toUpperCase(); });
        return name || "Audio";
    }
    function pwNodeForApp(appName) {
        for (var i = 0; i < root.audioApps.length; i++)
            if (root.bfAppKey(root.audioApps[i]) === appName) return root.audioApps[i];
        return null;
    }
    // toggle a device in lyre's active output set (multi-device fan-out), then re-sync
    function bfToggleOutput(dev) {
        var cur = (root.bfStatus.outputs || []).slice();
        var i = cur.indexOf(dev);
        if (i >= 0) cur.splice(i, 1); else cur.push(dev);
        if (cur.length === 0) cur = [dev];                 // never leave zero outputs
        root.run("lyre outputs " + cur.map(function (d) { return root.shq(d); }).join(" "));
        bfResync.restart();
    }
    // output selection: plain click switches to ONE device; Ctrl/Shift-click toggles it in the set (combine)
    function bfSetOutput(dev) { root.run("lyre outputs " + root.shq(dev)); bfResync.restart(); }
    // the Pipewire sink node for a device name, for per-output (hardware) volume
    function pwSinkForDev(name) {
        for (var i = 0; i < root.audioSinks.length; i++)
            if (root.audioSinks[i] && root.audioSinks[i].name === name) return root.audioSinks[i];
        return null;
    }
    // per-app output routing: "" = follow the lyre merge (system); else override to one device
    function bfRouteOf(app) { var r = root.bfStatus.app_route || ({}); return r[app] || ""; }
    function bfSetRoute(app, dev) {
        root.run("lyre route " + root.shq(app) + " " + (dev ? root.shq(dev) : "system"));
        bfResync.restart();
    }
    function bfDevShort(d) {                                // "USB Audio Device Analog Stereo" -> "USB"
        var s = (d && (d.description || d.name)) || "";
        return s.split(" ")[0] || s;
    }
    Timer { id: bfResync; interval: 450; onTriggered: root.bfRefresh() }

    // ----- state refresh (script-driven toggles + the live theme accent) -----
    Process { id: pAccent; command: ["sh","-c","grep -oE '#[0-9a-fA-F]{6}' $HOME/.local/state/glow/colors.css 2>/dev/null | head -1"]; running: true; stdout: StdioCollector { onStreamFinished: { var c = text.trim(); if (c.length === 7) root.accent = c; } } }
    Process { id: pWifi;  command: ["sh","-c","nmcli -t radio wifi 2>/dev/null"]; stdout: StdioCollector { onStreamFinished: root.wifiOn = text.trim() === "enabled" } }
    Process { id: pNight; command: ["sh","-c","pgrep -x hyprsunset >/dev/null || pgrep -x gammastep >/dev/null"]; onExited: (code) => root.nightOn = (code === 0) }
    Process { id: pSleep; command: ["sh","-c","[ \"$(cat $HOME/.local/state/glow/idle_inhibit 2>/dev/null)\" = 1 ]"]; onExited: (code) => root.nosleepOn = (code === 0) }
    Process { id: pProf;  command: ["sh","-c","powerprofilesctl get 2>/dev/null"]; stdout: StdioCollector { onStreamFinished: root.powerProfile = text.trim() || "balanced" } }
    Process { id: pRec;   command: ["sh","-c","pgrep -x wf-recorder >/dev/null"]; onExited: (code) => root.recOn = (code === 0) }
    function refresh() { pAccent.running = true; pWifi.running = true; pNight.running = true; pSleep.running = true; pProf.running = true; pRec.running = true; }

    // ----- weather (runs BONFIRE_WEATHER_CMD -> linecast --json; see features/flare/home.nix) -----
    property var wx: null
    function wxDay(d) { return Qt.formatDate(new Date(d), "ddd"); }
    Process {
        id: pWeather
        command: ["sh","-c","$BONFIRE_WEATHER_CMD 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: { try { var o = JSON.parse(text); if (o && o.current) root.wx = o; } catch (e) {} } }
    }
    Timer { running: true; interval: Math.max(1, root.hsGet("panel.weather.interval_min", 20)) * 60000; repeat: true; triggeredOnStart: true; onTriggered: pWeather.running = true }  // live via hearth

    // ----- live clock (top-right); ticks only while the panel is open -----
    property var clockNow: new Date()
    Timer { running: root.panelOpen; interval: 1000; repeat: true; triggeredOnStart: true; onTriggered: root.clockNow = new Date() }
    // uniform height for the control-grid tiles, so the 3-row grid matches the weather pill
    property real gridTileH: Math.max(46, (pillRect.implicitHeight - clockCol.implicitHeight - 36) / 3)

    // Fire-and-forget launcher. MUST be Quickshell.execDetached, NOT a tracked Process: a tracked
    // Process reaps its child's whole process group when the object exits or is reused for the next
    // command, which KILLS any daemon the command started. That is exactly why NIGHT was dead while
    // every other tile worked -- hyprsunset is a long-lived daemon that has to survive, whereas
    // nmcli / powerprofilesctl / the file writes are one-shot and had already exited, so the reap
    // never touched them. (setsid -f alone did NOT save it here: reusing the single `runner` Process
    // across clicks tore the session down.) execDetached runs fully detached + untracked -> nothing
    // reaps it; setsid keeps it in its own session too. Verified: the command works under the service env.
    function run(cmd) { console.log("[notif] run:", cmd); Quickshell.execDetached(["setsid","-f","sh","-c", cmd + " ; true"]); refreshTimer.restart(); }

    // ----- Wi-Fi picker state (nmcli; Bluetooth uses the native Quickshell.Bluetooth service) -----
    property var    wifiNets: []     // [{ ssid, signal, security, active }]
    property bool   wifiBusy: false
    property string wifiSel:  ""     // ssid awaiting credentials (secured + not already saved)
    property bool   wifiSelEnt: false // the selected network is WPA-Enterprise (802.1X: needs an identity + EAP)
    Process {
        id: pScan
        command: ["sh","-c","nmcli -t -f ACTIVE,SSID,SIGNAL,SECURITY dev wifi list --rescan yes 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: root.parseWifi(text) }
    }
    function wifiScan() { root.wifiBusy = true; pScan.running = true; pSaved.running = true; pWifiIP.running = true; }
    function parseWifi(txt) {
        // nmcli -t is colon-separated with ':' inside a field escaped as '\:'. ACTIVE + SIGNAL +
        // SECURITY never contain ':', so take the ends and rejoin the middle as the SSID.
        var out = [], seen = {};
        var lines = txt.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i]; if (!l) continue;
            var p = l.split(":"); if (p.length < 4) continue;
            var active   = p[0] === "yes";
            var security = p[p.length - 1];
            var signal   = parseInt(p[p.length - 2]) || 0;
            var ssid     = p.slice(1, p.length - 2).join(":").replace(/\\:/g, ":");
            if (!ssid) continue;
            out.push({ ssid: ssid, signal: signal, security: security, active: active, enterprise: security.indexOf("802.1X") >= 0 });
        }
        out.sort(function (a, b) { if (a.active !== b.active) return a.active ? -1 : 1; return b.signal - a.signal; });
        var dedup = [];
        for (var j = 0; j < out.length; j++) { if (seen[out[j].ssid]) continue; seen[out[j].ssid] = 1; dedup.push(out[j]); }
        if (dedup.length > 0 || !root.wifiOn) root.wifiNets = dedup;   // don't wipe a good list on a rate-limited empty rescan
        root.wifiBusy = false;
    }
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }  // single-quote for sh -c
    function sigIcon(s) { return s > 75 ? "󰤨" : (s > 50 ? "󰤥" : (s > 25 ? "󰤢" : (s > 10 ? "󰤟" : "󰤯"))); }  // 4-level wifi
    function btIcon(ic) {   // freedesktop device icon name -> nerd glyph
        ic = ic || "";
        if (ic.indexOf("headset") >= 0 || ic.indexOf("headphone") >= 0) return "󰋋";
        if (ic.indexOf("mouse") >= 0) return "󰍽";
        if (ic.indexOf("keyboard") >= 0) return "󰌌";
        if (ic.indexOf("phone") >= 0) return "󰄜";
        if (ic.indexOf("watch") >= 0) return "󰖉";
        if (ic.indexOf("speaker") >= 0 || ic.indexOf("audio") >= 0) return "󰓃";
        if (ic.indexOf("gaming") >= 0 || ic.indexOf("joystick") >= 0) return "󰊴";
        if (ic.indexOf("display") >= 0 || ic.indexOf("video") >= 0 || ic.indexOf("tv") >= 0) return "󰍹";
        return "󰂱";
    }
    // Best human name for a BT device: quickshell's name, else the bluetoothctl-resolved name,
    // else the MAC. A bare MAC-as-name (BlueZ's unresolved alias) is treated as "no name".
    property var btNames: ({})   // MAC(upper) -> resolved name, from `bluetoothctl devices`
    function btIsMac(s) { return /^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$/.test(String(s)); }
    function btLabel(dev) {
        var n = dev.name;
        if (n && !btIsMac(n) && n !== dev.address) return n;
        var r = root.btNames[String(dev.address).toUpperCase()];
        if (r && !btIsMac(r)) return r;
        return dev.address;
    }
    function btHasName(dev) { return root.btLabel(dev) !== dev.address; }   // a real name resolved (not a bare MAC)
    Process {
        id: pBtNames
        command: ["sh","-c","bluetoothctl devices 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: {
            var m = {}, lines = text.split("\n");
            for (var i = 0; i < lines.length; i++) {
                var mm = lines[i].match(/^Device ([0-9A-Fa-f:]{17}) (.+)$/);
                if (mm) m[mm[1].toUpperCase()] = mm[2];
            }
            root.btNames = m;
        } }
    }
    function wifiConnect(ssid, pw) {
        var c = "nmcli dev wifi connect " + shq(ssid);
        if (pw && pw.length > 0) c += " password " + shq(pw);
        root.run(c); root.wifiSel = "";
    }
    // WPA-Enterprise (802.1X): `nmcli dev wifi connect` can't express EAP, so build the profile. PEAP +
    // MSCHAPv2 is the near-universal school/eduroam default (ksa.hs.kr included). delete-then-add keeps
    // re-entry idempotent; NM validates the server cert against the system CA bundle. identity is typed
    // by the user (e.g. a student id or email) -- never pre-filled.
    function wifiConnectEnterprise(ssid, identity, pw) {
        var q = shq(ssid);
        var cmd = "nmcli connection delete id " + q + " 2>/dev/null; " +
                  "nmcli connection add type wifi con-name " + q + " ssid " + q +
                  " wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2" +
                  " 802-1x.identity " + shq(identity) + " 802-1x.password " + shq(pw) +
                  " && nmcli connection up id " + q;
        root.run(cmd); root.wifiSel = "";
    }
    // saved NM profiles (so a known network is one tap, and can be forgotten) + the live IPv4
    property var    wifiSaved: []
    property string wifiIP: ""
    Process { id: pSaved; command: ["sh","-c","nmcli -t -f NAME connection show 2>/dev/null"]
              stdout: StdioCollector { onStreamFinished: { var a = text.split("\n"), o = []; for (var i=0;i<a.length;i++) if (a[i]) o.push(a[i].replace(/\\:/g, ":")); root.wifiSaved = o; } } }
    Process { id: pWifiIP; command: ["sh","-c","d=$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | awk -F: '$2==\"wifi\"&&$3==\"connected\"{print $1;exit}'); [ -n \"$d\" ] && nmcli -g IP4.ADDRESS device show \"$d\" 2>/dev/null | head -1 | cut -d/ -f1"]
              stdout: StdioCollector { onStreamFinished: root.wifiIP = text.trim() } }
    function wifiSavedHas(ssid) { for (var i=0;i<root.wifiSaved.length;i++) if (root.wifiSaved[i] === ssid) return true; return false; }
    function wifiForget(ssid) { root.run("nmcli connection delete id " + shq(ssid)); root.wifiSel = ""; refreshTimer.restart(); }
    function wifiDisconnect(ssid) { root.run("nmcli connection down id " + shq(ssid)); }

    // ----- timers / stopwatch / pomodoro (MULTIPLE at once; each renders as a banner up top) -----
    function fmtTime(s) {
        s = Math.max(0, Math.floor(s));
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
        var mm = (m < 10 ? "0" : "") + m, xx = (x < 10 ? "0" : "") + x;
        return h > 0 ? (h + ":" + mm + ":" + xx) : (mm + ":" + xx);
    }
    // toast + a short chime. Both run even when the panel is closed (notify-send + pw-play are on the
    // service PATH; BONFIRE_ALERT_SOUND is set in features/flare/home.nix). 2>/dev/null so a missing
    // audio sink never swallows the toast. (title/body are literals here, so plain quoting is safe.)
    function timerAlert(title, body) {
        root.run("notify-send -a 'Bonfire Timer' '" + title + "' '" + body + "' ; pw-play \"$BONFIRE_ALERT_SOUND\" 2>/dev/null");
    }
    // composer state (the card at the bottom builds a new timer from these; MM:SS for a plain timer,
    // work/rest minutes for a pomodoro)
    property int newMin: 5
    property int newSec: 0
    property int pomoWorkMin: 25
    property int pomoRestMin: 5
    ListModel { id: timersModel }     // one row per live timer -> one banner each (so N at once just works)
    function addTimer() {
        var total = root.newMin * 60 + root.newSec;
        if (total <= 0) return;
        timersModel.append({ kind: "timer", label: root.fmtTime(total), secs: total, total: total,
                             running: true, done: false, phase: "", workSecs: 0, restSecs: 0 });
    }
    function addPomodoro() {
        var w = Math.max(1, root.pomoWorkMin) * 60, r = Math.max(1, root.pomoRestMin) * 60;
        timersModel.append({ kind: "pomodoro", label: "Pomodoro", secs: w, total: w,
                             running: true, done: false, phase: "work", workSecs: w, restSecs: r });
    }
    function addStopwatch() {
        timersModel.append({ kind: "stopwatch", label: "Stopwatch", secs: 0, total: 0,
                             running: true, done: false, phase: "", workSecs: 0, restSecs: 0 });
    }
    Timer {   // one 1Hz tick drives EVERY live timer in the model
        interval: 1000; repeat: true; running: timersModel.count > 0
        onTriggered: {
            for (var i = 0; i < timersModel.count; i++) {
                var t = timersModel.get(i);
                if (!t.running) continue;
                if (t.kind === "stopwatch") { timersModel.setProperty(i, "secs", t.secs + 1); continue; }
                if (t.secs > 1) { timersModel.setProperty(i, "secs", t.secs - 1); continue; }
                if (t.kind === "pomodoro") {
                    if (t.phase === "work") {
                        timersModel.setProperty(i, "phase", "break");
                        timersModel.setProperty(i, "secs", t.restSecs);
                        root.timerAlert("Break time", "Rest for " + Math.round(t.restSecs / 60) + " min");
                    } else {
                        timersModel.setProperty(i, "phase", "work");
                        timersModel.setProperty(i, "secs", t.workSecs);
                        root.timerAlert("Back to work", "Focus for " + Math.round(t.workSecs / 60) + " min");
                    }
                } else {
                    timersModel.setProperty(i, "secs", 0);
                    timersModel.setProperty(i, "running", false);
                    timersModel.setProperty(i, "done", true);
                    root.timerAlert("Timer done", root.fmtTime(t.total) + " is up");
                }
            }
        }
    }
    Timer { id: refreshTimer; interval: 250; onTriggered: root.refresh() }
    Timer { running: root.panelOpen; interval: 3000; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

    IpcHandler {
        target: "panel"
        function toggle(): void { root.panelOpen = !root.panelOpen; if (root.panelOpen) root.refresh(); }
        function show(): void { root.panelOpen = true; root.refresh(); }
        function hide(): void { root.panelOpen = false; }
    }

    // ======================= reusable widgets =======================
    // A toggle/action tile. active -> inverts to the accent (like the waybar chips).
    component Tile: Rectangle {
        id: tile
        property string icon: ""
        property string label: ""
        property bool active: false
        signal clicked()
        implicitWidth: 100
        implicitHeight: 62
        radius: root.hsGet("panel.radius.tile", 14)
        color: active ? root.accent : (ma.containsMouse ? root.bgTileHi : root.bgTile)
        Behavior on color { ColorAnimation { duration: 120 } }
        Column {
            anchors.centerIn: parent; spacing: 3
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: tile.icon; visible: text.length > 0; font.family: root.ff; font.pixelSize: 20; color: tile.active ? root.invFg : root.fg }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: tile.label; font.family: root.ff; font.pixelSize: 11; color: tile.active ? root.invFg : root.dim; visible: text.length > 0 }
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tile.clicked() }
    }

    // Scan/rescan button: idle = bgTile; while `busy`, the background blinks #777<->#fff (icon flips to
    // black), and on finish rises to #fff then fades back. Shared by the Wi-Fi + Bluetooth managers.
    component ScanButton: Rectangle {
        id: sb
        property bool busy: false
        signal clicked()
        implicitWidth: 40; implicitHeight: 30; radius: 9
        property real lvl: 0.47
        color: (sb.busy || sbSettle.running) ? Qt.rgba(sb.lvl, sb.lvl, sb.lvl, 1) : (sbMa.containsMouse ? root.bgTileHi : root.bgTile)
        onBusyChanged: { if (sb.busy) { sbSettle.stop(); sbBlink.restart(); } else { sbBlink.stop(); sbSettle.restart(); } }
        SequentialAnimation { id: sbBlink; running: false; loops: Animation.Infinite
            NumberAnimation { target: sb; property: "lvl"; to: 1.0; duration: 430; easing.type: Easing.InOutSine }
            NumberAnimation { target: sb; property: "lvl"; to: 0.47; duration: 430; easing.type: Easing.InOutSine }
        }
        SequentialAnimation { id: sbSettle; running: false
            NumberAnimation { target: sb; property: "lvl"; to: 1.0; duration: 260; easing.type: Easing.OutSine }
            NumberAnimation { target: sb; property: "lvl"; to: 0.07; duration: 440; easing.type: Easing.InSine }
        }
        Text { anchors.centerIn: parent; text: "󰑐"; font.family: root.ff; font.pixelSize: 15
               color: (sb.busy || sb.lvl > 0.5) ? root.invFg : root.fg }
        MouseArea { id: sbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sb.clicked() }
    }

    component SliderRow: RowLayout {
        id: sr
        property string icon: ""
        property real value: 0
        signal moved(real v)
        signal iconClicked()
        spacing: 12
        Text {
            text: sr.icon; font.family: root.ff; font.pixelSize: 20; color: root.fg; Layout.preferredWidth: 24; horizontalAlignment: Text.AlignHCenter
            MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: sr.iconClicked() }
        }
        Rectangle {
            Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
            height: 8; radius: 4; color: root.bgTile
            Rectangle { height: parent.height; radius: 4; color: root.accent; width: Math.max(0, Math.min(1, sr.value)) * parent.width }
            MouseArea {
                anchors.fill: parent; anchors.margins: -8   // fat hit target
                onPressed: (m) => sr.moved(Math.max(0, Math.min(1, m.x / width)))
                onPositionChanged: (m) => { if (pressed) sr.moved(Math.max(0, Math.min(1, m.x / width))); }
            }
        }
    }

    // Presets-first EQ: preset chips + an "Advanced" reveal of 10 vertical bands. Drives
    // `lyre eq <scope> <target> ...`; scope = "out" (per output device) | "app" (per app).
    component EqControl: ColumnLayout {
        id: eqc
        property string scope: "out"
        property string target: ""
        property var gains: root.bfGains(eqc.scope, eqc.target)   // initial from status; frozen once the user edits
        property bool adv: false
        spacing: 4
        function sendAll() { root.run("lyre eq " + eqc.scope + " " + root.shq(eqc.target) + " all " + eqc.gains.join(" ")); }
        function applyPreset(g) { eqc.gains = g.slice(); eqc.sendAll(); }
        function setBand(i, v) {
            var a = eqc.gains.slice(); a[i] = v; eqc.gains = a;
            root.run("lyre eq " + eqc.scope + " " + root.shq(eqc.target) + " " + i + " " + v);
        }
        function matchesPreset(g) {
            for (var i = 0; i < 10; i++) if (Math.abs((eqc.gains[i] || 0) - (g[i] || 0)) > 0.6) return false;
            return true;
        }
        RowLayout {
            Layout.fillWidth: true; spacing: 4
            Repeater {
                model: root.bfPresets
                delegate: Rectangle {
                    required property var modelData
                    property bool on: eqc.matchesPreset(modelData.g)
                    Layout.fillWidth: true; implicitHeight: 22; radius: 7
                    color: on ? root.accent : (pcMa.containsMouse ? root.bgTileHi : root.bgTile)
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Text { anchors.centerIn: parent; text: modelData.name; font.family: root.ff; font.pixelSize: 10
                           color: parent.on ? root.invFg : root.fg }
                    MouseArea { id: pcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: eqc.applyPreset(modelData.g) }
                }
            }
            Rectangle {
                implicitWidth: 30; implicitHeight: 22; radius: 7
                color: eqc.adv ? Qt.rgba(1, 1, 1, 0.13) : (advMa.containsMouse ? root.bgTileHi : root.bgTile)
                Text { anchors.centerIn: parent; text: "󰡰"; font.family: root.ff; font.pixelSize: 13; color: eqc.adv ? root.accent : root.fg }
                MouseArea { id: advMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: eqc.adv = !eqc.adv }
            }
        }
        // Advanced: a framed 10-band graphic EQ. Faders show a groove, a 0 dB centre line, an accent
        // fill from centre, a handle at the current level, and a live dB readout above.
        Rectangle {
            visible: eqc.adv
            Layout.fillWidth: true; Layout.topMargin: 2
            implicitHeight: eqRow.implicitHeight + 16
            radius: 10; color: Qt.rgba(1, 1, 1, 0.05); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.09)
            RowLayout {
                id: eqRow
                anchors.fill: parent; anchors.margins: 8; spacing: 0
                Repeater {
                    model: 10
                    delegate: ColumnLayout {
                        required property int index
                        Layout.fillWidth: true; spacing: 4
                        Text {                                       // live dB readout
                            Layout.alignment: Qt.AlignHCenter; Layout.preferredHeight: 10
                            text: (eqc.gains[index] > 0 ? "+" : "") + Math.round(eqc.gains[index] || 0)
                            visible: Math.abs(eqc.gains[index] || 0) >= 1
                            font.family: root.ff; font.pixelSize: 8; color: root.accent
                        }
                        Item {                                       // the fader
                            id: fader
                            Layout.alignment: Qt.AlignHCenter
                            implicitWidth: 18; implicitHeight: 74
                            Rectangle { anchors.horizontalCenter: parent.horizontalCenter      // groove
                                        width: 4; height: parent.height; radius: 2; color: root.bgTile }
                            Rectangle { anchors.horizontalCenter: parent.horizontalCenter      // 0 dB line
                                        y: parent.height / 2; width: 12; height: 1; color: root.dim }
                            Rectangle {                                                        // fill from centre
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 4; radius: 2; color: root.accent
                                property real frac: Math.max(-1, Math.min(1, (eqc.gains[index] || 0) / 12))
                                height: Math.abs(frac) * (parent.height / 2)
                                y: frac >= 0 ? (parent.height / 2 - height) : (parent.height / 2)
                            }
                            Rectangle {                                                        // handle
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 14; height: 5; radius: 2.5; color: root.fg
                                property real frac: Math.max(-1, Math.min(1, (eqc.gains[index] || 0) / 12))
                                y: (1 - (frac + 1) / 2) * (fader.height - height)
                            }
                            MouseArea {
                                anchors.fill: parent; anchors.leftMargin: -5; anchors.rightMargin: -5
                                function setFromY(yy) { eqc.setBand(index, Math.round((1 - 2 * Math.max(0, Math.min(1, yy / fader.height))) * 12)); }
                                onPressed: (m) => setFromY(m.y)
                                onPositionChanged: (m) => { if (pressed) setFromY(m.y); }
                            }
                        }
                        Text { Layout.alignment: Qt.AlignHCenter; text: root.bfBandLabels[index]; font.family: root.ff; font.pixelSize: 8; color: root.dim }
                    }
                }
            }
        }
    }

    // ======================= transient popups =======================
    PanelWindow {
        id: popups
        property var list: []
        function add(n) { list = list.concat([n]); popTimer.restart(); }
        visible: list.length > 0
        WlrLayershell.namespace: "flare-popup"
        WlrLayershell.layer: WlrLayer.Overlay
        anchors { top: true; right: true }
        margins { top: 12; right: 12 }
        exclusiveZone: 0
        implicitWidth: 400
        implicitHeight: Math.max(1, popCol.implicitHeight)
        color: "transparent"
        Timer { id: popTimer; interval: 5000; onTriggered: popups.list = [] }
        Column {
            id: popCol; width: parent.width; spacing: 8
            Repeater {
                model: popups.list
                delegate: Rectangle {
                    required property var modelData
                    width: popCol.width; radius: root.hsGet("panel.radius.notification", 16); color: root.bgPanel
                    implicitHeight: pc.implicitHeight + 24
                    Column {
                        id: pc; x: 16; y: 12; width: parent.width - 32; spacing: 3
                        Text { text: modelData.summary || modelData.appName || "Notification"; font.family: root.ff; color: root.fg; font.bold: true; font.pixelSize: 14; elide: Text.ElideRight; width: parent.width }
                        Text { text: modelData.body || ""; font.family: root.ff; color: root.dim; font.pixelSize: 12; wrapMode: Text.WordWrap; width: parent.width; visible: text.length > 0 }
                    }
                    MouseArea { anchors.fill: parent; onClicked: popups.list = [] }
                }
            }
        }
    }

    // ======================= the control panel =======================
    PanelWindow {
        id: panel
        visible: root.panelOpen
        // Renamed OFF "flare" so the compositor keystone (features/hyprland/trapezoid.patch,
        // which matches that prefix) NO LONGER warps this layer: the LAYER keystone mis-renders at a
        // fractional monitor scale (0.8 here), compressing the panel into the right ~45% with a dead
        // transparent left gutter (the "vertical bar"). Flat, full-width panel instead. To bring the
        // trapezoid back, fix the layer path's scale handling in the patch, then restore this name.
        WlrLayershell.namespace: "flare"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        // Anchor top + right + BOTTOM so the panel fills the FULL dock region vertically on ANY
        // monitor. It used to anchor only top/right with a hardcoded implicitHeight: 1198 -- which
        // matched only this screen's dock region and capped (or overflowed) on any other size. With
        // top+bottom anchored the height is now the monitor's: top 48 sits below the waybar's 56px
        // exclusive zone (56+48 = 104 = the pyre card's DOCK_Y), bottom 48 mirrors it, and the
        // span between them tracks the screen -- so it always matches the dock region.
        anchors { top: true; right: true; bottom: true }
        margins { top: 48; right: 40; bottom: 48 }
        exclusiveZone: 0
        implicitWidth: root.hsGet("panel.width", 800)     // live via hearth (hearth set panel.width …)
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            radius: root.hsGet("panel.radius.card", 20)
            color: root.bgPanel

            ColumnLayout {
                anchors { fill: parent; margins: 22 }
                spacing: 18

                // ---- top: weather as a vertical pill (left) + the control grid (right) ----
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    // weather pill -- compact vertical stack + a mini 5-day strip
                    Rectangle {
                        id: pillRect
                        visible: root.wx !== null
                        Layout.preferredWidth: 168
                        Layout.alignment: Qt.AlignTop
                        radius: 16; color: root.bgTile
                        implicitHeight: pillCol.implicitHeight + 28
                        ColumnLayout {
                            id: pillCol
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
                            spacing: 4
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                                   text: root.wx ? root.wx.location : ""; font.family: root.ff; font.pixelSize: 12; font.bold: true; color: root.fg }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                                   text: root.wx ? root.wx.current.icon : ""; font.family: root.ff; font.pixelSize: 44; color: root.fg }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                                   text: root.wx ? (Math.round(root.wx.current.temperature) + "°") : ""; font.family: root.ff; font.pixelSize: 34; color: root.fg }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                                   text: root.wx ? root.wx.current.condition : ""; font.family: root.ff; font.pixelSize: 11; color: root.dim }
                            RowLayout {
                                Layout.fillWidth: true
                                Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: root.wx ? ("H " + Math.round(root.wx.today.high) + "°") : ""; font.family: root.ff; font.pixelSize: 12; color: root.fg }
                                Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: root.wx ? ("L " + Math.round(root.wx.today.low) + "°") : ""; font.family: root.ff; font.pixelSize: 12; color: root.dim }
                            }
                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                                   text: (root.wx && root.wx.aqi) ? ("AQI " + root.wx.aqi.us_aqi + "  ·  " + root.wx.current.humidity + "% rh") : ""
                                   font.family: root.ff; font.pixelSize: 9; color: root.dim }
                            Rectangle { Layout.fillWidth: true; Layout.topMargin: 3; Layout.bottomMargin: 1; Layout.preferredHeight: 1; color: root.dim; opacity: 0.25 }
                            Repeater {   // vertical 5-day forecast
                                model: (root.wx && root.wx.daily) ? root.wx.daily.slice(0, 5) : []
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true; spacing: 6
                                    Text { text: root.wxDay(modelData.date); font.family: root.ff; font.pixelSize: 10; color: root.dim; Layout.preferredWidth: 28 }
                                    Text { text: modelData.icon; font.family: root.ff; font.pixelSize: 13; color: root.fg }
                                    Item { Layout.fillWidth: true }
                                    Text { text: Math.round(modelData.high) + "°"; font.family: root.ff; font.pixelSize: 11; color: root.fg }
                                    Text { text: Math.round(modelData.low) + "°"; font.family: root.ff; font.pixelSize: 10; color: root.dim; Layout.preferredWidth: 22; horizontalAlignment: Text.AlignRight }
                                }
                            }
                        }
                    }

                    // right column: large centered clock on top + the control grid below
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.alignment: Qt.AlignTop; spacing: 16
                        Item {   // clock line: clock centered, power pinned to the right
                            Layout.fillWidth: true
                            implicitHeight: clockCol.implicitHeight
                            ColumnLayout {
                                id: clockCol
                                anchors.centerIn: parent
                                spacing: -2
                                Text { Layout.alignment: Qt.AlignHCenter; horizontalAlignment: Text.AlignHCenter; text: Qt.formatDateTime(root.clockNow, root.hsGet("panel.clock.time_format", "HH:mm")); font.family: root.ff; font.pixelSize: root.hsGet("panel.clock.size", 58); color: root.fg }
                                Text { Layout.alignment: Qt.AlignHCenter; horizontalAlignment: Text.AlignHCenter; text: Qt.formatDate(root.clockNow, root.hsGet("panel.clock.date_format", "dddd, MMMM d")); font.family: root.ff; font.pixelSize: 12; color: root.dim }
                            }
                            Rectangle {   // power: bare icon, no background so it blends in (faint wash on hover only)
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                implicitWidth: 44; implicitHeight: 44; radius: 22
                                color: pwrMa.containsMouse ? root.bgTile : "transparent"
                                Behavior on color { ColorAnimation { duration: 120 } }
                                Text { anchors.centerIn: parent; text: "󰐥"; font.family: root.ff; font.pixelSize: 22; color: powerMenu.open ? root.accent : root.fg }
                                MouseArea { id: pwrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { powerMenu.open = !powerMenu.open; if (powerMenu.open) { wifiMenu.open = false; btMenu.open = false; soundMenu.open = false; } } }
                            }
                        }
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 4; rowSpacing: 10; columnSpacing: 10
                        Tile { Layout.fillWidth: true; Layout.preferredHeight: root.gridTileH; icon: root.wifiOn ? "󰤨" : "󰤭"; label: "Wi-Fi"; active: root.wifiOn
                               onClicked: { wifiMenu.open = !wifiMenu.open; if (wifiMenu.open) { btMenu.open = false; powerMenu.open = false; soundMenu.open = false; root.wifiScan(); } } }
                        Tile { Layout.fillWidth: true; Layout.preferredHeight: root.gridTileH; icon: "󰂯"; label: "Bluetooth"; active: Bluetooth.defaultAdapter ? Bluetooth.defaultAdapter.enabled : false
                               onClicked: { btMenu.open = !btMenu.open; if (btMenu.open) { wifiMenu.open = false; powerMenu.open = false; soundMenu.open = false; } } }
                        Tile { Layout.fillWidth: true; Layout.preferredHeight: root.gridTileH; icon: root.dnd ? "󰂛" : "󰂚"; label: "DND"; active: root.dnd; onClicked: root.dnd = !root.dnd }
                        Tile { Layout.fillWidth: true; Layout.preferredHeight: root.gridTileH; icon: "󰒲"; label: "No Sleep"; active: root.nosleepOn
                               onClicked: root.run("f=$HOME/.local/state/glow/idle_inhibit; mkdir -p \"$(dirname $f)\"; [ \"$(cat $f 2>/dev/null)\" = 1 ] && echo 0 > $f || echo 1 > $f") }
                        Tile { Layout.fillWidth: true; Layout.preferredHeight: root.gridTileH; icon: "󰛨"; label: "Night"; active: root.nightOn; onClicked: root.run("$HOME/.local/bin/nightlight_toggle.sh") }
                        Tile { Layout.fillWidth: true; Layout.preferredHeight: root.gridTileH   // battery mode -- cycles Eco -> Balanced -> Perf
                               icon: root.powerProfile === "power-saver" ? "󰌪" : (root.powerProfile === "balanced" ? "󰂏" : "󱐋")
                               label: root.powerProfile === "power-saver" ? "Eco" : (root.powerProfile === "balanced" ? "Balanced" : "Perf")
                               onClicked: root.run("powerprofilesctl set " + (root.powerProfile === "power-saver" ? "balanced" : (root.powerProfile === "balanced" ? "performance" : "power-saver"))) }
                        Tile { Layout.fillWidth: true; Layout.preferredHeight: root.gridTileH; icon: "󰕾"; label: "Sound"; active: soundMenu.open
                               onClicked: { soundMenu.open = !soundMenu.open; if (soundMenu.open) { wifiMenu.open = false; btMenu.open = false; powerMenu.open = false; } } }
                        Tile { Layout.fillWidth: true; Layout.preferredHeight: root.gridTileH; icon: root.recOn ? "󰓛" : "󰕧"; label: root.recOn ? "Stop" : "Record"; active: root.recOn
                               onClicked: { root.panelOpen = false; root.run("if pgrep -x wf-recorder >/dev/null; then pkill -INT -x wf-recorder; notify-send 'Recording' 'Saved to ~/Videos'; else f=\"$HOME/Videos/rec-$(date +%Y%m%d-%H%M%S).mp4\"; mkdir -p \"$(dirname \"$f\")\"; setsid -f wf-recorder -f \"$f\" >/dev/null 2>&1; notify-send 'Recording' 'Started'; fi") } }
                        Tile { Layout.fillWidth: true; Layout.preferredHeight: root.gridTileH; icon: "󰈋"; label: "Pick"
                               onClicked: { root.panelOpen = false; root.run("sleep 0.2; hyprpicker -a -f hex >/dev/null 2>&1 && notify-send 'Color picker' 'Hex copied to clipboard'") } }
                        // ---- timer pill: 1 row x 3 cols. left = mode-cycle button; right = per-mode input ----
                        Rectangle {
                            id: timerPill
                            Layout.columnSpan: 3; Layout.fillWidth: true; Layout.preferredHeight: root.gridTileH
                            radius: 14; color: root.bgTile
                            property string mode: "timer"   // cycles stopwatch -> timer -> pomodoro (same idea as the battery tile)
                            RowLayout {
                                anchors { fill: parent; margins: 7 }
                                spacing: 7
                                Tile {   // mode cycle button (left third)
                                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.fillHeight: true; radius: 10
                                    icon: timerPill.mode === "stopwatch" ? "󰔛" : (timerPill.mode === "timer" ? "󰔟" : "󰅐")
                                    label: timerPill.mode === "stopwatch" ? "Stopwatch" : (timerPill.mode === "timer" ? "Timer" : "Pomodoro")
                                    onClicked: timerPill.mode = timerPill.mode === "stopwatch" ? "timer" : (timerPill.mode === "timer" ? "pomodoro" : "stopwatch")
                                }
                                Tile {   // STOPWATCH: start button (right two-thirds)
                                    visible: timerPill.mode === "stopwatch"
                                    Layout.fillWidth: true; Layout.preferredWidth: 2; Layout.fillHeight: true; radius: 10
                                    icon: "󰐊"; label: "Start stopwatch"; onClicked: root.addStopwatch()
                                }
                                Rectangle {   // TIMER: one mm:ss input (right two-thirds)
                                    visible: timerPill.mode === "timer"
                                    Layout.fillWidth: true; Layout.preferredWidth: 2; Layout.fillHeight: true; radius: 10; color: root.bgPanel
                                    TextInput {
                                        id: timerField; anchors.fill: parent; anchors.margins: 4
                                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                        font.family: root.ff; font.pixelSize: 24; color: root.fg
                                        selectByMouse: true; cursorVisible: activeFocus
                                        validator: RegularExpressionValidator { regularExpression: /^[0-9]{0,3}:?[0-9]{0,2}$/ }
                                        onAccepted: {
                                            var p = timerField.text.split(":"); var mm = parseInt(p[0]) || 0; var ss = (p.length > 1 ? parseInt(p[1]) : 0) || 0;
                                            root.newMin = Math.min(999, mm); root.newSec = Math.min(59, ss);
                                            if (root.newMin * 60 + root.newSec > 0) root.addTimer();
                                            timerField.text = ""; timerField.focus = false;
                                        }
                                        Text { anchors.centerIn: parent; visible: !timerField.text && !timerField.activeFocus; text: "mm:ss  ↵"; color: root.dim; font: timerField.font }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onClicked: { timerField.forceActiveFocus(); timerField.selectAll(); } }
                                    }
                                }
                                RowLayout {   // POMODORO: work + break inputs (right two-thirds); 2nd enter starts
                                    visible: timerPill.mode === "pomodoro"
                                    Layout.fillWidth: true; Layout.preferredWidth: 2; Layout.fillHeight: true; spacing: 7
                                    Rectangle {
                                        Layout.fillWidth: true; Layout.fillHeight: true; radius: 10; color: root.bgPanel
                                        TextInput {
                                            id: pomoWorkField; anchors.fill: parent; anchors.margins: 4
                                            horizontalAlignment: Text.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                            font.family: root.ff; font.pixelSize: 22; color: root.fg
                                            selectByMouse: true; cursorVisible: activeFocus
                                            validator: IntValidator { bottom: 1; top: 999 }
                                            onAccepted: { pomoBreakField.forceActiveFocus(); pomoBreakField.selectAll(); }
                                            Text { anchors.centerIn: parent; visible: !pomoWorkField.text && !pomoWorkField.activeFocus; text: "work ↵"; color: root.dim; font: pomoWorkField.font }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onClicked: { pomoWorkField.forceActiveFocus(); pomoWorkField.selectAll(); } }
                                        }
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true; Layout.fillHeight: true; radius: 10; color: root.bgPanel
                                        TextInput {
                                            id: pomoBreakField; anchors.fill: parent; anchors.margins: 4
                                            horizontalAlignment: Text.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                                            font.family: root.ff; font.pixelSize: 22; color: root.fg
                                            selectByMouse: true; cursorVisible: activeFocus
                                            validator: IntValidator { bottom: 1; top: 999 }
                                            onAccepted: {
                                                root.pomoWorkMin = Math.max(1, parseInt(pomoWorkField.text) || 25);
                                                root.pomoRestMin = Math.max(1, parseInt(pomoBreakField.text) || 5);
                                                root.addPomodoro();
                                                pomoWorkField.text = ""; pomoBreakField.text = ""; pomoBreakField.focus = false;
                                            }
                                            Text { anchors.centerIn: parent; visible: !pomoBreakField.text && !pomoBreakField.activeFocus; text: "break ↵"; color: root.dim; font: pomoBreakField.font }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onClicked: { pomoBreakField.forceActiveFocus(); pomoBreakField.selectAll(); } }
                                        }
                                    }
                                }
                            }
                        }
                        }
                    }
                }

                // Wi-Fi picker (nmcli). Click the Wi-Fi tile to open; pick a network to connect
                // (saved/open connect straight away; a secured new one shows a password field).
                ColumnLayout {
                    id: wifiMenu; property bool open: false
                    visible: open; Layout.fillWidth: true; spacing: 7
                    RowLayout {
                        Layout.fillWidth: true; spacing: 10
                        Text { text: root.wifiOn ? "󰤨" : "󰤭"; font.family: root.ff; font.pixelSize: 16; color: root.fg }
                        Text { text: "Wi-Fi"; font.family: root.ff; font.pixelSize: 14; font.bold: true; color: root.fg; Layout.fillWidth: true }
                        Tile { implicitWidth: 56; implicitHeight: 30; radius: 9; label: root.wifiOn ? "On" : "Off"; active: root.wifiOn
                               onClicked: root.run("nmcli radio wifi " + (root.wifiOn ? "off" : "on")) }
                        ScanButton { busy: root.wifiBusy; onClicked: root.wifiScan() }
                    }
                    Repeater {
                        model: root.wifiNets
                        delegate: Rectangle {
                            id: netRow
                            required property var modelData
                            property bool saved: root.wifiSavedHas(modelData.ssid)
                            Layout.fillWidth: true; implicitHeight: 44; radius: 10
                            color: modelData.active ? Qt.rgba(1, 1, 1, 0.13) : (wna.containsMouse ? root.bgTileHi : root.bgTile)
                            border.width: modelData.active ? 1 : 0; border.color: root.accent
                            MouseArea {
                                id: wna; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (modelData.active) return;
                                    if ((modelData.security && modelData.security !== "") && !netRow.saved) { root.wifiSel = modelData.ssid; root.wifiSelEnt = modelData.enterprise === true; }
                                    else root.wifiConnect(modelData.ssid, "");
                                }
                            }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 8; spacing: 10
                                Text { text: root.sigIcon(modelData.signal); font.family: root.ff; font.pixelSize: 16; color: modelData.active ? root.accent : root.fg }
                                ColumnLayout {
                                    spacing: 0; Layout.fillWidth: true
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 5
                                        Text { text: modelData.ssid; font.family: root.ff; font.pixelSize: 13; color: root.fg; elide: Text.ElideRight; Layout.fillWidth: true }
                                        Text { visible: modelData.security && modelData.security !== ""; text: "󰌾"; font.family: root.ff; font.pixelSize: 10; color: root.dim }
                                    }
                                    Text {
                                        text: modelData.active ? ("connected" + (root.wifiIP ? "  ·  " + root.wifiIP : "")) : (netRow.saved ? ("saved  ·  " + modelData.signal + "%") : (modelData.signal + "%"))
                                        font.family: root.ff; font.pixelSize: 10; color: modelData.active ? root.accent : root.dim
                                    }
                                }
                                Tile { visible: modelData.active; implicitWidth: 34; implicitHeight: 30; radius: 8; icon: "󰖪"; onClicked: root.wifiDisconnect(modelData.ssid) }
                                Tile { visible: netRow.saved; implicitWidth: 34; implicitHeight: 30; radius: 8; icon: "󰩹"; onClicked: root.wifiForget(modelData.ssid) }
                            }
                        }
                    }
                    Text { visible: root.wifiNets.length === 0; text: root.wifiBusy ? "Scanning…" : "No networks"; font.family: root.ff; font.pixelSize: 11; color: root.dim }
                    ColumnLayout {   // credentials for a selected secured network (PSK: password; enterprise: identity + password)
                        visible: root.wifiSel !== ""
                        Layout.fillWidth: true; spacing: 6
                        onVisibleChanged: if (visible) { if (root.wifiSelEnt) idField.forceActiveFocus(); else pwField.forceActiveFocus(); }
                        Rectangle {   // identity / username (WPA-Enterprise 802.1X only)
                            visible: root.wifiSelEnt
                            Layout.fillWidth: true; implicitHeight: 34; radius: 8; color: root.bgTile
                            onVisibleChanged: if (visible) idField.forceActiveFocus()
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8
                                Text { text: "󰀄"; font.family: root.ff; font.pixelSize: 13; color: root.dim }
                                TextInput {
                                    id: idField; Layout.fillWidth: true; clip: true
                                    enabled: root.wifiSel !== ""   // disabled while hidden -> can't hold focus or draw a caret
                                    color: root.fg; font.family: root.ff; font.pixelSize: 12; verticalAlignment: TextInput.AlignVCenter
                                    onAccepted: pwField.forceActiveFocus()
                                    Text { anchors.fill: parent; visible: !idField.text; verticalAlignment: Text.AlignVCenter
                                           text: "Username / identity"; color: root.dim; font: idField.font }
                                }
                            }
                        }
                        Rectangle {   // password (PSK key, or the 802.1X password)
                            Layout.fillWidth: true; implicitHeight: 34; radius: 8; color: root.bgTile
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8
                                Text { text: "󰌾"; font.family: root.ff; font.pixelSize: 13; color: root.dim }
                                TextInput {
                                    id: pwField; Layout.fillWidth: true; clip: true
                                    enabled: root.wifiSel !== ""   // disabled while hidden -> can't hold focus or draw a caret
                                    color: root.fg; font.family: root.ff; font.pixelSize: 12
                                    echoMode: TextInput.Password; verticalAlignment: TextInput.AlignVCenter
                                    onAccepted: {
                                        if (root.wifiSelEnt) root.wifiConnectEnterprise(root.wifiSel, idField.text, text);
                                        else root.wifiConnect(root.wifiSel, text);
                                        text = "";
                                    }
                                    Text { anchors.fill: parent; visible: !pwField.text; verticalAlignment: Text.AlignVCenter
                                           text: "Password · " + root.wifiSel + "  ↵"; color: root.dim; font: pwField.font }
                                }
                            }
                        }
                    }
                }

                // Bluetooth picker (native Quickshell.Bluetooth). Click the Bluetooth tile to open.
                ColumnLayout {
                    id: btMenu; property bool open: false
                    visible: open; Layout.fillWidth: true; spacing: 7
                    property var adapter: Bluetooth.defaultAdapter
                    // opening the menu auto-scans so unpaired devices resolve their real names (phone/mac style)
                    onOpenChanged: { if (btMenu.adapter) btMenu.adapter.discovering = btMenu.open; if (btMenu.open) pBtNames.running = true; }
                    Timer { running: btMenu.open; interval: 2000; repeat: true; triggeredOnStart: true; onTriggered: pBtNames.running = true }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 10
                        Text { text: "󰂯"; font.family: root.ff; font.pixelSize: 16; color: root.fg }
                        Text { text: "Bluetooth"; font.family: root.ff; font.pixelSize: 14; font.bold: true; color: root.fg; Layout.fillWidth: true }
                        Tile { implicitWidth: 56; implicitHeight: 30; radius: 9; label: (btMenu.adapter && btMenu.adapter.enabled) ? "On" : "Off"; active: btMenu.adapter ? btMenu.adapter.enabled : false
                               onClicked: if (btMenu.adapter) btMenu.adapter.enabled = !btMenu.adapter.enabled }
                        ScanButton { busy: btMenu.adapter ? btMenu.adapter.discovering : false; onClicked: if (btMenu.adapter) btMenu.adapter.discovering = !btMenu.adapter.discovering }
                    }
                    Repeater {
                        model: Bluetooth.devices
                        delegate: Rectangle {
                            id: btRow
                            required property var modelData
                            property bool paired: (modelData.paired || modelData.bonded) || false
                            // show paired/connected always; while scanning, only NAMED discoveries (hide nameless BLE noise, like win/mac)
                            visible: modelData.connected || btRow.paired || ((btMenu.adapter && btMenu.adapter.discovering) && root.btHasName(modelData))
                            Layout.fillWidth: true; implicitHeight: 44; radius: 10
                            color: modelData.connected ? Qt.rgba(1, 1, 1, 0.13) : (bda.containsMouse ? root.bgTileHi : root.bgTile)
                            border.width: modelData.connected ? 1 : 0; border.color: root.accent
                            MouseArea {
                                id: bda; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { if (modelData.connected) modelData.disconnect(); else modelData.connect(); }
                            }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 8; spacing: 10
                                Text { text: root.btIcon(modelData.icon); font.family: root.ff; font.pixelSize: 16; color: modelData.connected ? root.accent : root.fg }
                                ColumnLayout {
                                    spacing: 0; Layout.fillWidth: true
                                    Text { text: root.btLabel(modelData); font.family: root.ff; font.pixelSize: 13; color: root.fg; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text {
                                        text: modelData.connected ? ("connected" + (modelData.batteryAvailable ? ("  ·  󰁹 " + Math.round(modelData.battery * 100) + "%") : "")) : (btRow.paired ? "paired" : "tap to pair")
                                        font.family: root.ff; font.pixelSize: 10; color: modelData.connected ? root.accent : root.dim
                                    }
                                }
                                Tile { visible: btRow.paired; implicitWidth: 34; implicitHeight: 30; radius: 8; icon: "󰩹"; onClicked: { if (modelData.forget) modelData.forget(); } }
                            }
                        }
                    }
                    Text { visible: !btMenu.adapter || !btMenu.adapter.enabled; text: "Bluetooth is off"; font.family: root.ff; font.pixelSize: 11; color: root.dim }
                }

                RowLayout {
                    id: powerMenu; property bool open: false
                    visible: open; Layout.fillWidth: true; spacing: 12
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 48; icon: "󰌾"; label: "Lock"; onClicked: { root.run("$HOME/.local/bin/lock.sh"); powerMenu.open = false; } }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 48; icon: "󰗽"; label: "Exit"; onClicked: root.run("$HOME/.local/bin/exit.sh") }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 48; icon: "󰜉"; label: "Reboot"; onClicked: root.run("systemctl reboot") }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 48; icon: "󰐥"; label: "Off"; onClicked: root.run("systemctl poweroff") }
                }

                // volume + brightness
                SliderRow {
                    Layout.fillWidth: true; Layout.preferredHeight: 24
                    icon: (Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio && Pipewire.defaultAudioSink.audio.muted) ? "󰝟" : "󰕾"
                    value: (Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio) ? Pipewire.defaultAudioSink.audio.volume : 0
                    onMoved: (v) => { if (Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio) { Pipewire.defaultAudioSink.audio.volume = v; Pipewire.defaultAudioSink.audio.muted = false; } }
                    onIconClicked: { if (Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio) Pipewire.defaultAudioSink.audio.muted = !Pipewire.defaultAudioSink.audio.muted; }
                }

                // ---- Sound: expanded mixer -- lyre outputs + per-output EQ + per-app volume/EQ + input ----
                ColumnLayout {
                    id: soundMenu; property bool open: false
                    visible: open; Layout.fillWidth: true; spacing: 8
                    onOpenChanged: if (open) root.bfRefresh()
                    Timer { running: soundMenu.open; interval: 2000; repeat: true; triggeredOnStart: true; onTriggered: root.bfRefresh() }

                    Text { visible: !root.bfStatus.lyre && root.bfDevList.length === 0
                           text: "Sound engine starting…"; font.family: root.ff; font.pixelSize: 11; color: root.dim }

                    // ---- output devices: lyre fans out to one OR several at once; each active one gets its own EQ ----
                    Text { visible: root.bfDevList.length > 0; text: "Output  ·  click = switch, ⇧ = combine"; font.family: root.ff; font.pixelSize: 11; color: root.dim }
                    Repeater {
                        model: root.bfDevList
                        delegate: ColumnLayout {
                            id: odev
                            required property var modelData
                            property bool isOut: (root.bfStatus.outputs || []).indexOf(modelData.name) >= 0
                            Layout.fillWidth: true; spacing: 4
                            Rectangle {
                                Layout.fillWidth: true; implicitHeight: 38; radius: 10
                                color: odev.isOut ? Qt.rgba(1, 1, 1, 0.13) : (skMa.containsMouse ? root.bgTileHi : root.bgTile)
                                border.width: odev.isOut ? 1 : 0; border.color: root.accent
                                MouseArea { id: skMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            // plain click = switch to this one; Ctrl/Shift-click = combine (toggle in the set)
                                            onClicked: (m) => { if (m.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) root.bfToggleOutput(odev.modelData.name); else root.bfSetOutput(odev.modelData.name); } }
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                                    Text { text: "󰓃"; font.family: root.ff; font.pixelSize: 15; color: odev.isOut ? root.accent : root.fg }
                                    Text { text: odev.modelData.description || odev.modelData.name; font.family: root.ff; font.pixelSize: 12; color: root.fg; Layout.fillWidth: true; elide: Text.ElideRight }
                                    Text { visible: odev.isOut; text: "󰄬"; font.family: root.ff; font.pixelSize: 13; color: root.accent }
                                }
                            }
                            // per-output (hardware) volume for this device, shown when it's an active output
                            SliderRow {
                                visible: odev.isOut && root.pwSinkForDev(odev.modelData.name) !== null
                                Layout.fillWidth: true; Layout.leftMargin: 6; Layout.preferredHeight: 20
                                property var snk: root.pwSinkForDev(odev.modelData.name)
                                icon: (snk && snk.audio && snk.audio.muted) ? "󰝟" : "󰕾"
                                value: (snk && snk.audio) ? snk.audio.volume : 0
                                onMoved: (v) => { if (snk && snk.audio) { snk.audio.volume = v; snk.audio.muted = false; } }
                                onIconClicked: { if (snk && snk.audio) snk.audio.muted = !snk.audio.muted; }
                            }
                            EqControl { visible: odev.isOut; Layout.fillWidth: true; Layout.leftMargin: 6; scope: "out"; target: odev.modelData.name }
                        }
                    }

                    // ---- apps: volume via Pipewire, EQ via lyre (keyed by lyre's app name) ----
                    Text { visible: root.bfAppList.length > 0; Layout.topMargin: 2; text: "Apps"; font.family: root.ff; font.pixelSize: 11; color: root.dim }
                    Repeater {
                        model: root.bfAppList
                        delegate: ColumnLayout {
                            id: arow
                            required property var modelData       // lyre app key (clean name)
                            property var node: root.pwNodeForApp(modelData)
                            Layout.fillWidth: true; spacing: 2
                            Text { text: arow.modelData; font.family: root.ff; font.pixelSize: 11; color: root.fg; elide: Text.ElideRight; Layout.fillWidth: true }
                            SliderRow {
                                visible: arow.node !== null
                                Layout.fillWidth: true; Layout.preferredHeight: 22
                                icon: (arow.node && arow.node.audio && arow.node.audio.muted) ? "󰝟" : "󰕾"
                                value: (arow.node && arow.node.audio) ? arow.node.audio.volume : 0
                                onMoved: (v) => { if (arow.node && arow.node.audio) { arow.node.audio.volume = v; arow.node.audio.muted = false; } }
                                onIconClicked: { if (arow.node && arow.node.audio) arow.node.audio.muted = !arow.node.audio.muted; }
                            }
                            // output routing: follow the system merge, or override to one specific device
                            RowLayout {
                                Layout.fillWidth: true; Layout.leftMargin: 6; spacing: 4
                                Text { text: "󰳟"; font.family: root.ff; font.pixelSize: 12; color: root.dim }
                                Rectangle {
                                    implicitHeight: 20; radius: 6; Layout.preferredWidth: sysT.implicitWidth + 16
                                    property bool on: root.bfRouteOf(arow.modelData) === ""
                                    color: parent.on ? root.accent : (sysMa.containsMouse ? root.bgTileHi : root.bgTile)
                                    Behavior on color { ColorAnimation { duration: 100 } }
                                    Text { id: sysT; anchors.centerIn: parent; text: "System"; font.family: root.ff; font.pixelSize: 9; color: parent.on ? root.invFg : root.fg }
                                    MouseArea { id: sysMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.bfSetRoute(arow.modelData, "") }
                                }
                                Repeater {
                                    model: root.bfDevList
                                    delegate: Rectangle {
                                        required property var modelData
                                        implicitHeight: 20; radius: 6; Layout.fillWidth: true
                                        property bool on: root.bfRouteOf(arow.modelData) === modelData.name
                                        color: on ? root.accent : (rMa.containsMouse ? root.bgTileHi : root.bgTile)
                                        Behavior on color { ColorAnimation { duration: 100 } }
                                        Text { anchors.centerIn: parent; text: root.bfDevShort(modelData); font.family: root.ff; font.pixelSize: 9; color: parent.on ? root.invFg : root.fg; elide: Text.ElideRight; width: parent.width - 8; horizontalAlignment: Text.AlignHCenter }
                                        MouseArea { id: rMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.bfSetRoute(arow.modelData, modelData.name) }
                                    }
                                }
                            }
                            EqControl { Layout.fillWidth: true; Layout.leftMargin: 6; scope: "app"; target: arow.modelData }
                        }
                    }
                    Text { visible: root.bfAppList.length === 0 && root.bfStatus.lyre; text: "Nothing playing"; font.family: root.ff; font.pixelSize: 11; color: root.dim }

                    // ---- input ----
                    Text { Layout.topMargin: 2; text: "Input"; font.family: root.ff; font.pixelSize: 11; color: root.dim }
                    SliderRow {
                        Layout.fillWidth: true; Layout.preferredHeight: 22
                        icon: (Pipewire.defaultAudioSource && Pipewire.defaultAudioSource.audio && Pipewire.defaultAudioSource.audio.muted) ? "󰍭" : "󰍬"
                        value: (Pipewire.defaultAudioSource && Pipewire.defaultAudioSource.audio) ? Pipewire.defaultAudioSource.audio.volume : 0
                        onMoved: (v) => { if (Pipewire.defaultAudioSource && Pipewire.defaultAudioSource.audio) { Pipewire.defaultAudioSource.audio.volume = v; Pipewire.defaultAudioSource.audio.muted = false; } }
                        onIconClicked: { if (Pipewire.defaultAudioSource && Pipewire.defaultAudioSource.audio) Pipewire.defaultAudioSource.audio.muted = !Pipewire.defaultAudioSource.audio.muted; }
                    }
                }
                SliderRow {
                    id: brightRow
                    Layout.fillWidth: true; Layout.preferredHeight: 24
                    icon: "󰃟"
                    property real cur: 0.5
                    value: cur
                    onMoved: (v) => { cur = v; root.run("brightnessctl set " + Math.round(v*100) + "%"); }
                    Process { id: pBright; command: ["sh","-c","brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d %"]; stdout: StdioCollector { onStreamFinished: { var n = parseFloat(text.trim()); if (!isNaN(n)) brightRow.cur = n/100; } } }
                    Timer { running: root.panelOpen; interval: 3000; repeat: true; triggeredOnStart: true; onTriggered: pBright.running = true }
                }

                // music (mpris)
                Rectangle {
                    id: musicCard
                    Layout.fillWidth: true; radius: 16; color: root.bgTile
                    implicitHeight: 76
                    property var player: Mpris.players.values.length > 0 ? Mpris.players.values[0] : null
                    visible: player !== null
                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 12
                        Rectangle {   // album-art thumbnail (note-icon placeholder when there's no art)
                            Layout.preferredWidth: 48; Layout.preferredHeight: 48
                            radius: 8; color: root.bgPanel; clip: true
                            Image {
                                id: artImg; anchors.fill: parent
                                source: (musicCard.player && musicCard.player.trackArtUrl) ? musicCard.player.trackArtUrl : ""
                                fillMode: Image.PreserveAspectCrop; sourceSize.width: 96; sourceSize.height: 96
                                asynchronous: true; cache: true; visible: status === Image.Ready
                            }
                            Text {
                                anchors.centerIn: parent; visible: artImg.status !== Image.Ready
                                text: "󰎆"; font.family: root.ff; font.pixelSize: 22; color: root.dim
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 2
                            Text { text: musicCard.player ? (musicCard.player.trackTitle || "—") : "—"; font.family: root.ff; color: root.fg; font.bold: true; font.pixelSize: 14; elide: Text.ElideRight; Layout.fillWidth: true }
                            Text { text: musicCard.player ? (musicCard.player.trackArtist || "") : ""; font.family: root.ff; color: root.dim; font.pixelSize: 12; elide: Text.ElideRight; Layout.fillWidth: true }
                        }
                        Tile { implicitWidth: 46; implicitHeight: 46; icon: "󰒮"; onClicked: { if (musicCard.player && musicCard.player.canGoPrevious) musicCard.player.previous(); } }
                        Tile { implicitWidth: 46; implicitHeight: 46; icon: (musicCard.player && musicCard.player.isPlaying) ? "󰏤" : "󰐊"; onClicked: { if (musicCard.player && musicCard.player.canTogglePlaying) musicCard.player.togglePlaying(); } }
                        Tile { implicitWidth: 46; implicitHeight: 46; icon: "󰒭"; onClicked: { if (musicCard.player && musicCard.player.canGoNext) musicCard.player.next(); } }
                    }
                }

                // notifications header
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Notifications"; font.family: root.ff; color: root.fg; font.bold: true; font.pixelSize: 16; Layout.fillWidth: true }
                    Tile { implicitWidth: 72; implicitHeight: 32; radius: 9; label: "Clear"; onClicked: { for (var i = server.trackedNotifications.values.length - 1; i >= 0; i--) server.trackedNotifications.values[i].dismiss(); } }
                }

                // ---- active timer banners: pinned at the top of the notification area ----
                Repeater {
                    model: timersModel
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        radius: 14
                        implicitHeight: 54
                        color: model.done ? Qt.rgba(1, 1, 1, 0.08)
                                          : (model.running ? Qt.rgba(1, 1, 1, 0.14) : root.bgTile)
                        border.width: model.running ? 1 : 0
                        border.color: root.accent
                        RowLayout {
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 16; rightMargin: 10 }
                            spacing: 12
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: model.kind === "pomodoro" ? "󰅐" : (model.kind === "stopwatch" ? "󰔛" : "󰔟")
                                font.family: root.ff; font.pixelSize: 22
                                color: model.done ? root.dim : (model.running ? root.accent : root.fg)
                            }
                            ColumnLayout {
                                Layout.alignment: Qt.AlignVCenter
                                Layout.fillWidth: true
                                spacing: 1
                                Text {
                                    Layout.fillWidth: true; elide: Text.ElideRight
                                    text: model.kind === "pomodoro"
                                          ? ("Pomodoro · " + (model.phase === "work" ? "Focus" : "Break"))
                                          : (model.kind === "stopwatch" ? "Stopwatch" : ("Timer · " + model.label))
                                    font.family: root.ff; font.pixelSize: 11; color: root.dim
                                }
                                Text {
                                    text: model.done ? "done" : root.fmtTime(model.secs)
                                    font.family: root.ff; font.pixelSize: 23
                                    color: model.done ? root.dim : (model.running ? root.accent : root.fg)
                                }
                            }
                            Tile {
                                Layout.alignment: Qt.AlignVCenter
                                visible: !model.done
                                implicitWidth: 40; implicitHeight: 36; radius: 11
                                icon: model.running ? "󰏤" : "󰐊"
                                onClicked: timersModel.setProperty(index, "running", !model.running)
                            }
                            Tile {
                                Layout.alignment: Qt.AlignVCenter
                                implicitWidth: 40; implicitHeight: 36; radius: 11
                                icon: "󰅖"
                                onClicked: timersModel.remove(index)
                            }
                        }
                    }
                }

                // notifications list
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true; spacing: 8
                    model: server.trackedNotifications
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width; radius: 14; color: root.bgTile
                        implicitHeight: nc.implicitHeight + 22
                        Column {
                            id: nc; x: 14; y: 11; width: parent.width - 28; spacing: 2
                            Text { text: modelData.summary || modelData.appName || ""; font.family: root.ff; color: root.fg; font.bold: true; font.pixelSize: 14; elide: Text.ElideRight; width: parent.width }
                            Text { text: modelData.body || ""; font.family: root.ff; color: root.dim; font.pixelSize: 12; wrapMode: Text.WordWrap; width: parent.width; visible: text.length > 0 }
                        }
                        MouseArea { anchors.fill: parent; onClicked: modelData.dismiss() }
                    }
                    Text { anchors.centerIn: parent; visible: parent.count === 0; text: "No notifications"; font.family: root.ff; color: root.dim; font.pixelSize: 13 }
                }
            }
        }
    }
}
