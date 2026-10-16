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

    /*
      Two possible rotation sources, and the lock means a different thing to
      each -- see my.desktop.autorotate.

        "iio"          iio-hyprland/iio-niri. No pause switch of their own, so
                       "lock" kills the listener and "unlock" respawns it.
        "motion-cues"  the vehicleMotionCues plugin, which owns the
                       accelerometer for its dots and therefore also serves
                       orientation. It HAS a real lock, so this entry just
                       flips it over IPC and leaves the sensor alone -- the
                       cues keep running while rotation is held still, which
                       is exactly what you want in a moving vehicle.

      Both paths stay reachable from the same control-centre entry so the lock
      is independent of whether the cues are on.
    */
    readonly property string source: pluginData.source || "iio"
    readonly property bool viaMotionCues: source === "motion-cues"

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
        command: root.viaMotionCues
            ? ["dms", "ipc", "call", "vehicleMotionCues", "rotationLockState"]
            : ["pgrep", "-x", root.autorotateProcessName]
        running: false

        // pgrep answers by exit code; the IPC call answers on stdout.
        stdout: SplitParser {
            onRead: line => {
                if (root.viaMotionCues)
                    root.locked = String(line).trim() === "locked"
            }
        }

        onExited: (exitCode) => {
            if (!root.viaMotionCues)
                root.locked = exitCode !== 0
            root.known = true
        }
    }

    Process {
        id: cueLockProcess
        running: false
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
        if (!viaMotionCues && !compositor) {
            ToastService.showError("Rotation Lock", "No compositor configured for this plugin")
            return
        }
        locked = !locked
        if (viaMotionCues) {
            // The plugin owns the lock; nothing is killed or respawned, so the
            // motion cues carry on drawing while rotation is held.
            cueLockProcess.command = ["dms", "ipc", "call", "vehicleMotionCues",
                                      locked ? "lockRotation" : "unlockRotation"]
            cueLockProcess.running = true
        } else if (locked) {
            killProcess.running = true
        } else {
            respawnProcess.running = true
        }
        ToastService.showInfo("Rotation Lock", locked ? "Orientation locked" : "Auto-rotate resumed")
    }

    Component.onCompleted: {
        if (viaMotionCues || compositor) {
            statusProcess.running = true
        } else {
            known = true
        }
    }
}
