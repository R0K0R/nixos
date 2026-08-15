import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

/*
  iio-niri/iio-hyprland (wayland/niri.nix, wayland/hyprland.nix) have no
  pause switch of their own, so "lock" means kill the autorotate listener
  and "unlock" means respawn the exact command those files already
  spawn-at-startup/exec-once. compositor/monitor come from plugin_settings.json
  (programs.dank-material-shell.plugins.rotationLock.settings in plugins.nix)
  since a QML plugin can't read osConfig.wm.compositor itself.

  Initial state is read from whether the listener is actually running
  (pgrep), not persisted -- persisting a "locked" flag across DMS restarts
  would drift from reality if the compositor session itself never restarted.
*/
PluginComponent {
    id: root

    readonly property string compositor: pluginData.compositor || ""
    readonly property string monitor: pluginData.monitor || "eDP-1"
    property bool locked: false
    property bool known: false

    readonly property string autorotateProcessName: compositor === "niri" ? "iio-niri" : "iio-hyprland"
    readonly property var autorotateCommand: compositor === "niri"
        ? ["iio-niri", "listen", "--monitor", monitor]
        : ["iio-hyprland", monitor]

    Process {
        id: statusProcess
        command: ["pgrep", "-x", root.autorotateProcessName]
        running: false
        onExited: (exitCode) => {
            root.locked = exitCode !== 0
            root.known = true
        }
    }

    // -9/SIGKILL, not a bare pkill (SIGTERM): iio-hyprland's own SIGTERM
    // handler calls dbus_disconnect() on its shared bus connection (obtained
    // via dbus_bus_get()), which libdbus treats as a fatal API misuse and
    // aborts (confirmed via journalctl -- systemd-coredump, signal 6/ABRT,
    // _dbus_abort <- dbus_disconnect <- main). A plain SIGTERM kill crashes
    // the daemon instead of cleanly exiting, and since nothing supervises it
    // (no systemd unit, just a startup exec-once), it then stays dead until
    // the next manual unlock. SIGKILL bypasses that handler entirely.
    Process {
        id: killProcess
        command: ["pkill", "-9", "-x", root.autorotateProcessName]
        running: false
    }

    // Spawned detached (new session, backgrounded, disowned), not as
    // `root.autorotateCommand` directly: DMS destroys this plugin's whole
    // component tree -- including this Process -- every time the
    // control-center panel closes, and Quickshell kills whatever child a
    // Process object still owns when its QML object is destroyed (same
    // mechanism OskToggle.qml relies on for `running: false` to kill wvkbd
    // cleanly). Confirmed live: without detaching, "unlock" only lasted
    // until the panel closed, then autorotate silently locked again. `sh`
    // itself exits right after backgrounding, so by the time Quickshell's
    // kill-on-destroy fires, the real daemon has already been reparented
    // away from this process tree and is unaffected.
    Process {
        id: respawnProcess
        command: [
            "sh", "-c",
            "setsid \"$@\" </dev/null >/dev/null 2>&1 & disown; exit 0",
            "sh"
        ].concat(root.autorotateCommand)
        running: false
    }

    ccWidgetIcon: locked ? "screen_lock_rotation" : "screen_rotation"
    ccWidgetPrimaryText: "Rotation Lock"
    ccWidgetSecondaryText: !known ? "..." : (locked ? "Locked" : "Auto")
    ccWidgetIsActive: locked

    onCcWidgetToggled: {
        if (!compositor) {
            ToastService.showError("Rotation Lock", "No compositor configured for this plugin")
            return
        }
        locked = !locked
        if (locked) {
            killProcess.running = true
        } else {
            respawnProcess.running = true
        }
        ToastService.showInfo("Rotation Lock", locked ? "Orientation locked" : "Auto-rotate resumed")
    }

    Component.onCompleted: {
        if (compositor) {
            statusProcess.running = true
        } else {
            known = true
        }
    }
}
