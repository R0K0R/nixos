// Bound is required to reach `root` from inside the bar-pill Components, and it
// pairs with the delegate's `required property index`. Without it qmllint
// reports every root.* reference as unqualified access.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Widgets
import qs.Common
import qs.Modules.Plugins

/*
  A compact, PAGE-RELATIVE workspace strip.

  Two things the stock DankBar switcher cannot do, which is why this exists
  rather than a settings tweak:

  1. It draws the index and the app icons TOGETHER. The only condition that
     suppresses the number keys off a custom per-workspace icon
     (`loadedHasIcon: loadedIconData !== null`), never off app icons, so every
     occupied pill is "1 <icon>" -- about twice the width it needs. Here an
     occupied slot is just its icon; the number is what an EMPTY slot shows,
     and what every slot shows while Super is held.

  2. Its pill width floors at widgetHeight * 0.7, and widgetHeight comes from
     bar thickness, so "much smaller" is unreachable without shrinking every
     other widget. Owning the delegate means owning the sizing.

  PAGING is the real point. Slot N is not workspace N -- it is
  `page * 10 + N`, where the page follows whichever workspace is focused. Walk
  onto workspace 11 and the strip relabels 1..10, with Super+1 now going to 11.
  So the digits keep meaning "first slot in the group I am looking at" instead
  of an absolute id nobody can remember once past ten.

  The keybinds do the same arithmetic independently -- see
  features/hyprland/home.nix. Nothing is written down twice: both sides derive
  the page from the live focused workspace, so they cannot drift.

  BOTH ORIENTATIONS come off one inline `Slot` component. An earlier version
  defined only horizontalBarPill, which left the vertical bar with nothing
  usable to render -- the strip has to flip its long axis, not just be handed
  the same Row.
*/
PluginComponent {
    id: root

    readonly property int pageSize: 10
    readonly property int activeId: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1
    // Workspaces are 1-based, so subtract before dividing: 1..10 -> page 0.
    readonly property int page: Math.max(0, Math.floor((activeId - 1) / pageSize))
    readonly property int base: page * pageSize

    /*
      Super held. Tracked as STATE, not as edges.

      GlobalShortcut offers both a pressed/released signal pair and a `pressed`
      bool property. Driving this from the signals means a single missed edge
      latches the peek on forever -- which is exactly what happened: Hyprland
      does not deliver the modifier's release when the hold was USED for a
      combo (Super+1, Super+W), the same tap-detection that makes `bindr` on a
      modifier behave as a tap.

      Binding to the property instead means any correction Hyprland or
      Quickshell makes to the state propagates on its own, and `peekOverride`
      lets us force it down locally without fighting that binding.
    */
    readonly property bool peeking: peekHeld && !peekOverride
    property bool peekOverride: false
    // Set only once Super has been held past peekDelay -- see that Timer.
    property bool peekHeld: false

    // id -> workspace, rebuilt whenever the model changes. A map rather than a
    // per-delegate scan so the strip stays O(n) instead of O(n^2).
    readonly property var wsById: {
        const m = ({});
        const list = (Hyprland.workspaces && Hyprland.workspaces.values) ? Hyprland.workspaces.values : [];
        for (var i = 0; i < list.length; i++) {
            const w = list[i];
            if (w && w.id !== undefined)
                m[w.id] = w;
        }
        return m;
    }

    /*
      Memoised icon lookup.

      DesktopEntries.heuristicLookup() scans the desktop-entry set and is the
      one genuinely expensive call in this file. It was being made from inside
      IconImage.source, a BINDING -- so it re-ran for every visible slot on
      every window event, ten lookups each time a window opened, closed or
      moved. Resolution is a pure function of the app id, so it is cached
      permanently; the map is bounded by the number of distinct apps ever seen,
      which is tiny.

      moddedAppId matches what the stock switcher feeds the lookup, so icon
      resolution agrees with the rest of the bar instead of quietly differing
      for apps that need the fixup.
    */
    property var iconCache: ({})

    function iconFor(appId) {
        if (!appId)
            return "";
        if (iconCache[appId] !== undefined)
            return iconCache[appId];
        const modded = Paths.moddedAppId(appId);
        const resolved = Paths.getAppIcon(modded, DesktopEntries.heuristicLookup(modded));
        iconCache[appId] = resolved;
        return resolved;
    }

    /*
      Urgency OUTSIDE the visible page. Only ten slots are drawn, so a window
      demanding attention on workspace 23 while you are looking at page 0 would
      otherwise be completely invisible -- a regression the stock switcher does
      not have, because it never hides workspaces behind a page. A single
      marker at the end of the strip says "something wants you elsewhere"
      without pretending to show where.
    */
    readonly property bool offPageUrgent: {
        const list = (Hyprland.workspaces && Hyprland.workspaces.values) ? Hyprland.workspaces.values : [];
        for (var i = 0; i < list.length; i++) {
            const w = list[i];
            if (!w || !w.urgent)
                continue;
            if (w.id <= base || w.id > base + pageSize)
                return true;
        }
        return false;
    }

    /*
      Hyprland's global-shortcuts protocol, not a keybind that toggles a file.
      The protocol delivers press AND release, which is exactly the hold
      gesture; a plain `bind` only ever fires once and would need a matching
      release bind plus shared state. Bound compositor-side in
      features/hyprland/home.nix as hl.dsp.global("dms-workspaces:peek").
    */
    GlobalShortcut {
        id: peekShortcut
        appid: "dms-workspaces"
        name: "peek"
        description: "Reveal workspace numbers while held"
        onPressed: {
            root.peekOverride = false;
            peekDelay.restart();
            peekSafety.restart();
        }
        onReleased: {
            peekDelay.stop();
            peekSafety.stop();
            root.peekHeld = false;
        }
    }

    /*
      Hold-intent gate.

      Super is a modifier before it is a gesture: every Super+1, Super+W and
      Super+Return begins with a Super press. Reacting to that press
      immediately makes the whole strip relabel itself for a few milliseconds
      on every single shortcut -- a flicker on the most common thing you do.

      So the peek only arms once Super has been down this long without
      resolving into a combo. end-4's dots gate the same gesture the same way
      (superPressAndHeldTimer, Config.qml default 140ms); 200ms is a touch
      more patient, which suits a strip that is read rather than glanced at.
    */
    Timer {
        id: peekDelay
        interval: 200
        repeat: false
        onTriggered: root.peekHeld = true
    }

    /*
      Failsafe for a release that never arrives.

      Hyprland fires a plain bind on key-down only, so without the matching
      release bind the client gets `pressed` and nothing else -- and a latched
      peek is indistinguishable from "hold is broken", because the numbers just
      stay up forever. The release bind exists now (features/hyprland/home.nix),
      but a dropped event, a reload mid-hold, or a focus change during the press
      would strand it again.

      Nobody holds a peek for eight seconds, so timing out costs nothing real
      and turns a permanently wedged bar into a brief glitch.
    */
    Timer {
        id: peekSafety
        // 3s, not 8. The failsafe is now a backstop behind the `pressed`
        // property rather than the only recovery, and a genuine read of the
        // strip is well under three seconds -- so a stuck peek self-clears
        // fast enough not to be noticed as breakage.
        interval: 3000
        repeat: false
        onTriggered: { root.peekOverride = true; root.peekHeld = false; }
    }

    /*
      Clear the peek as soon as the workspace changes.

      Hyprland does not deliver the modifier's release when the hold was USED
      for a combo: press Super, press 1, let go, and the release bind never
      fires -- that is the same tap-detection behaviour that makes `bindr` on a
      modifier work as a tap. So Super+1 would leave the numbers latched until
      the 8s failsafe, on the single most common interaction there is.

      Navigating is itself proof the peek is over, so this is both the fix and
      the natural semantic: the numbers exist to tell you where to go, and you
      have gone.
    */
    onActiveIdChanged: {
        peekOverride = true;
        peekHeld = false;
        peekDelay.stop();
        peekSafety.stop();
    }

    // One slot, orientation-agnostic. `len` runs along the bar, `thick` across
    // it, and the two map onto width/height depending on which way the bar is
    // pointing.
    component Slot: Item {
        id: slot
        required property int index
        property bool vertical: false

        readonly property int wsId: root.base + index + 1
        readonly property var ws: root.wsById[wsId] ?? null
        readonly property var wins: (ws && ws.toplevels && ws.toplevels.values) ? ws.toplevels.values : []
        readonly property bool occupied: wins.length > 0
        readonly property bool active: wsId === root.activeId
        readonly property bool urgent: (ws && ws.urgent) ?? false

        // Empty slots show their number, so they need digit room -- 16 fits
        // "10" at 10px. Occupied slots carry a 14px icon.
        // A resting empty slot is only a 4px dot, so it needs no digit room.
        // While peeking it grows to fit "10" -- the strip widens for as long as
        // the key is held, which is the moment you are actually reading it.
        // A resting empty slot is a 4px dot and needs no digit room. It grows
        // to fit a two-digit id only while peeking -- the strip widens for as
        // long as the key is held, which is exactly when you are reading it.
        readonly property real len: active ? 24 : (occupied ? 20 : (root.peeking ? 20 : 10))
        readonly property real thick: 20

        width: vertical ? thick : len
        height: vertical ? len : thick

        Behavior on width {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
        Behavior on height {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }

        // Colour alone is easy to miss in peripheral vision, and an urgent slot
        // may be a bare digit rather than a bright icon.
        SequentialAnimation on opacity {
            running: slot.urgent && !slot.active
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.45; duration: 600; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
        }

        Rectangle {
            anchors.fill: parent
            radius: Math.min(width, height) / 2
            // Same precedence the stock switcher uses
            // (isActive ? active : isUrgent ? urgent : occupied ...): standing
            // on a workspace clears its urgency anyway, so active winning
            // loses nothing.
            color: slot.active
                ? Theme.primary
                : slot.urgent
                    ? Theme.error
                    : (slot.occupied ? Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.12) : "transparent")
            border.width: (slot.active || slot.urgent) ? 0 : (slot.occupied ? 1 : 0)
            border.color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.18)

            /*
              THE RESTING STATE, and the whole shape of the widget:

                occupied  ->  app icon
                empty     ->  a quiet dot
                peeking   ->  the index, on EVERY slot, icons included

              So holding Super relabels the entire strip at once rather than
              filling in the gaps. An earlier revision showed the index on
              empty slots permanently; that is a different widget, and it costs
              the width that made a compact strip worth building.
            */
            Rectangle {
                visible: !root.peeking && !slot.occupied && !slot.active && !slot.urgent
                anchors.centerIn: parent
                width: 4
                height: 4
                radius: 2
                color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.35)
            }

            Text {
                // Peek shows every id. Outside a peek, the FOCUSED slot shows
                // its id when it has no windows -- otherwise the slot you are
                // standing on would be the one blank pill on the strip, since
                // it has neither an icon to draw nor a dot (the dot is
                // suppressed on the active slot by design).
                visible: root.peeking || (slot.active && !slot.occupied)
                anchors.centerIn: parent
                // The ACTUAL workspace id, not the slot digit. On page 1 this
                // reads 11..20 while Super+1 still goes to 11 -- the label
                // answers "where am I" and the keybind stays "first slot of
                // this group". Showing 1..10 on every page made the strip
                // indistinguishable between pages, which defeated paging.
                text: String(slot.wsId)
                font.pixelSize: 10
                font.bold: slot.active
                color: (slot.active || slot.urgent)
                    ? Theme.background
                    : Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b,
                              slot.occupied ? 0.95 : 0.45)
            }

            IconImage {
                visible: !root.peeking && slot.occupied
                anchors.centerIn: parent
                width: 14
                height: 14
                source: {
                    if (!slot.occupied)
                        return "";
                    const w = slot.wins[0];
                    const o = w ? w.lastIpcObject : null;
                    return root.iconFor(o ? (o.class || o.initialClass || "") : "");
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                // LUA dispatch form, not the legacy one. configType = "lua"
                // routes dispatch through hl.dispatch(), where the bare
                // "workspace 3" dies with "')' expected near '3'" -- so the
                // obvious spelling silently did nothing when clicked. Focusing
                // a slot whose workspace does not exist yet creates it, which
                // is what makes empty dots clickable at all.
                onClicked: Hyprland.dispatch("hl.dsp.focus({ workspace = " + slot.wsId + " })")
            }
        }
    }

    // "Something wants you on another page." Deliberately just a dot: it cannot
    // say which workspace without drawing slots we do not have room for, and a
    // wrong hint is worse than a vague one.
    component OffPageDot: Rectangle {
        visible: root.offPageUrgent
        width: 6
        height: 6
        radius: 3
        color: Theme.error

        SequentialAnimation on opacity {
            running: root.offPageUrgent
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.4; duration: 600; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: 3
            Repeater {
                model: root.pageSize
                delegate: Slot {
                    vertical: false
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                }
            }
            OffPageDot { anchors.verticalCenter: parent.verticalCenter }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 3
            Repeater {
                model: root.pageSize
                delegate: Slot {
                    vertical: true
                    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
                }
            }
            OffPageDot { anchors.horizontalCenter: parent.horizontalCenter }
        }
    }
}
