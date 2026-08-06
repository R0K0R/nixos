import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

/*
  Holding a blocking systemd-inhibit lock for the process lifetime, rather
  than toggling logind settings, keeps this reversible by construction: DMS
  restarting or crashing just drops the child process and the inhibitor
  along with it, instead of leaving the machine stuck non-suspending.

  handle-lid-switch is the part that actually satisfies "even with the lid
  closed" -- logind's default LidSwitchIgnoreInhibited=yes means an active
  handle-lid-switch inhibitor makes it skip the configured lid action
  (session-services.nix: HandleLidSwitch=suspend) entirely.

  That also means logind takes no action at all on lid close while this is
  on -- no lock, no screen-off, just a lit unlocked display inside a closed
  lid. wayland/hyprland.nix's switch:off/on:"Lid Switch" bindl entries cover
  that: Hyprland reads the raw libinput switch event directly (independent
  of logind), and gate on this inhibitor's --who= tag being held to lock +
  DPMS-off on close and DPMS-on on open, without suspending.
*/
PluginComponent {
    id: root

    readonly property bool active: inhibitProcess.running

    Process {
        id: inhibitProcess
        command: [
            "systemd-inhibit",
            "--what=idle:sleep:handle-lid-switch",
            "--who=DMS No Sleep plugin",
            "--why=User requested",
            "--mode=block",
            "sleep",
            "infinity"
        ]
        running: false
    }

    ccWidgetIcon: "coffee"
    ccWidgetPrimaryText: "No Sleep"
    ccWidgetSecondaryText: active ? "Suspend blocked" : "Off"
    ccWidgetIsActive: active

    onCcWidgetToggled: {
        inhibitProcess.running = !inhibitProcess.running
        ToastService.showInfo("No Sleep", inhibitProcess.running ? "Suspend blocked -- lid close will lock + blank the screen instead" : "Suspend re-enabled")
    }
}
