import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Common
import qs.Services

/*
  Alt-Tab: the DMS launcher's tile view as a window switcher.

  Derived from AvengeMedia/dms-plugins DankHyprlandWindows 1.0.0
  (rev 3ad0e78, MIT). That plugin lists Hyprland windows in the launcher
  with live screencopy previews (TileItem renders a ScreencopyView for any
  item that carries a toplevelId we can resolve via getToplevelById), but
  orders them GEOMETRICALLY -- monitor, workspace, x -- via
  CompositorService.sortedToplevels. A switcher wants recency: the focused
  window first, the one you were in before it second, and so on, which is
  the one thing changed here. The FOCUSED window goes LAST: the first tile
  is the window you were in before this one, so Alt+Tab, Enter switches
  straight back, and the focused window is still listed for completeness.

  Recency comes from two sources, in this order of trust:
    1. our own MRU list, fed by ToplevelManager.activeToplevel every time
       focus moves -- always current, never waits on an IPC refresh;
    2. Hyprland's focusHistoryID from the toplevel's last IPC object, for
       windows focus has not touched since the shell started (0 = focused,
       1 = previous, ...). It can be stale between refreshes, which is why
       it is only the fallback.

  Bound compositor-side in features/dms/compositor.nix as
  `dms ipc call spotlight openQuery !` on Alt+Tab (`openQuery`, not
  `toggleQuery`, so a second Alt+Tab while it is up does not close it).
  Inside the launcher: arrows or Ctrl+J/K move, Enter focuses, Escape
  cancels. Tab cycles launcher categories, not items -- a launcher-level
  binding this plugin cannot change.

  No hold-Alt/release-to-commit: the workspaces plugin found that Hyprland
  does not deliver a modifier's release once the hold was used for a combo,
  so a release-driven switcher would latch. Not worth fighting.
*/
QtObject {
    id: root

    property var pluginService: null
    property string pluginId: "altTab"
    property string trigger: "!"
    property var toplevelRegistry: ({})
    property int _updateTrigger: 0

    // Most-recently-used Hyprland addresses, most recent first.
    property var mru: []

    signal itemsChanged

    property Connections compositorConn: Connections {
        target: CompositorService

        function onToplevelsChanged() {
            _updateTrigger++;
            requestUpdate();
        }
    }

    property Connections focusConn: Connections {
        target: ToplevelManager

        function onActiveToplevelChanged() {
            const address = root.addressOf(ToplevelManager.activeToplevel);
            if (!address)
                return;
            const next = [address];
            for (const a of root.mru) {
                if (a !== address)
                    next.push(a);
            }
            root.mru = next;
            requestUpdate();
        }
    }

    function requestUpdate() {
        if (!pluginService || !pluginId)
            return;
        if (typeof pluginService.requestLauncherUpdate === "function")
            pluginService.requestLauncherUpdate(pluginId);
    }

    Component.onCompleted: {
        if (pluginService)
            trigger = pluginService.loadPluginData(pluginId, "trigger", "!");
    }

    onTriggerChanged: {
        if (!pluginService)
            return;
        pluginService.savePluginData(pluginId, "trigger", trigger);
    }

    function getToplevelById(id) {
        return toplevelRegistry[id] || null;
    }

    // Hyprland address ("0x...") for a Wayland toplevel, via the Hyprland
    // toplevel that wraps it; empty when unknown.
    function addressOf(toplevel) {
        if (!toplevel)
            return "";
        const hyprToplevels = Hyprland.toplevels?.values;
        if (!hyprToplevels)
            return "";
        for (const ht of hyprToplevels) {
            if (ht?.wayland === toplevel)
                return ht.lastIpcObject?.address || "";
        }
        return "";
    }

    function windowSelector(address) {
        if (!address)
            return "";
        const normalized = address.toString().startsWith("0x") ? address.toString() : `0x${address}`;
        return `address:${normalized}`;
    }

    function focusWindow(address) {
        const selector = windowSelector(address);
        if (!selector)
            return;

        if (Hyprland.usingLua === false)
            Hyprland.dispatch(`focuswindow ${selector}`);
        else
            Hyprland.dispatch(`hl.dsp.focus({ window = "${selector}" })`);
    }

    function closeWindow(address) {
        const selector = windowSelector(address);
        if (!selector)
            return;

        if (Hyprland.usingLua === false)
            Hyprland.dispatch(`closewindow ${selector}`);
        else
            Hyprland.dispatch(`hl.dsp.window.close({window = "${selector}"})`);
    }

    // Lower sorts first. The focused window is sent to the very end so the
    // first tile is the previous one. Otherwise: MRU rank when we have seen
    // the window take focus, else Hyprland's own focus history, pushed
    // behind every MRU entry.
    function recencyKey(address, ipc, focused) {
        if (focused)
            return 1e9;
        const i = mru.indexOf(address);
        if (i >= 0)
            return i;
        const fh = ipc?.focusHistoryID;
        return 100000 + (typeof fh === "number" ? fh : 99999);
    }

    function getItems(query) {
        if (!CompositorService.isHyprland)
            return [];

        const sortedToplevels = CompositorService.sortedToplevels;
        if (!sortedToplevels || sortedToplevels.length === 0)
            return [];

        const hyprToplevels = Hyprland.toplevels?.values;
        if (!hyprToplevels)
            return [];

        const hyprMap = new Map();
        for (const ht of hyprToplevels) {
            if (ht?.wayland)
                hyprMap.set(ht.wayland, ht);
        }

        const lowerQuery = (query || "").toLowerCase().trim();
        const newRegistry = {};
        const items = [];

        for (let i = 0; i < sortedToplevels.length; i++) {
            const toplevel = sortedToplevels[i];
            if (!toplevel)
                continue;

            const hyprToplevel = hyprMap.get(toplevel);
            const ipc = hyprToplevel?.lastIpcObject;
            const address = ipc?.address || "";

            if (!address)
                continue;

            const appId = toplevel.appId || ipc?.class || "";
            const title = toplevel.title || ipc?.title || "";

            if (lowerQuery.length > 0) {
                const searchText = `${appId} ${title}`.toLowerCase();
                if (!searchText.includes(lowerQuery))
                    continue;
            }

            const wsId = ipc?.workspace?.id ?? hyprToplevel?.workspace?.id;
            const wsName = ipc?.workspace?.name || hyprToplevel?.workspace?.name || (wsId ? `Workspace ${wsId}` : "");

            const desktopEntry = DesktopEntries.heuristicLookup(Paths.moddedAppId(appId));
            const iconPath = Paths.getAppIcon(appId, desktopEntry) || Quickshell.iconPath("application-x-executable", "image-missing");

            const toplevelId = `hypr_${address}`;
            newRegistry[toplevelId] = toplevel;

            items.push({
                id: address,
                name: title || appId,
                icon: iconPath,
                comment: wsName ? `${appId} • ${wsName}` : appId,
                action: `focus:${address}`,
                categories: ["Alt-Tab"],
                toplevelId: toplevelId,
                attribution: iconPath,
                hyprAddress: address,
                _isFocused: toplevel.activated || false,
                _recency: recencyKey(address, ipc, toplevel.activated || false)
            });
        }

        // Stable: equal keys keep the geometric order they arrived in.
        items.sort((a, b) => a._recency - b._recency);

        toplevelRegistry = newRegistry;
        return items;
    }

    function executeItem(item) {
        if (!item?.action)
            return;
        if (!item.action.startsWith("focus:"))
            return;

        const address = item.action.substring(6);
        if (!address)
            return;

        focusWindow(address);
    }

    function getContextMenuActions(item) {
        if (!item?.hyprAddress)
            return [];

        const address = item.hyprAddress;
        return [
            {
                icon: "close",
                text: I18n.tr("Close Window"),
                action: () => {
                    closeWindow(address);
                }
            }
        ];
    }
}
