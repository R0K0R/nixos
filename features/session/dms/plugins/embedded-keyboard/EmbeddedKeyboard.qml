import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

/*
  Temporarily disable the BUILT-IN keyboard, leaving external ones alive.

  WHY NOT A HYPRLAND DEVICE RULE. The obvious
  `device[at-translated-set-2-keyboard]:enabled = false` does nothing here,
  because keyd sits underneath with `[ids] *` -- it grabs every physical
  keyboard and re-emits through keyd-virtual-keyboard, so that is the device
  Hyprland actually receives from. Disabling the virtual one instead would take
  every external keyboard down with it, which is the opposite of the point.
  EVIOCGRAB is out for the same reason: keyd already holds an exclusive grab.

  So the disable happens BELOW keyd, by unbinding the i8042 port from the atkbd
  driver -- see features/embedded-keyboard/nixos.nix, which owns the unit and
  the polkit rule. The evdev node disappears, keyd notices the removal, and
  nothing upstream sees the keyboard at all.

  State lives in the unit, not in this component: DankBar builds one instance
  per bar, and a plugin-local bool would let the compact bar disagree with the
  main one (the No Sleep plugin's old bug). `systemctl is-active` is the single
  source of truth, shared through PluginService the same way.
*/
PluginComponent {
    id: root

    readonly property string unit: "embedded-keyboard-disabled.service"

    readonly property var shared: PluginService.globalVars[pluginId] || ({})
    readonly property bool known: shared.known === true
    // "off" = the keyboard is disabled, i.e. the unit is ACTIVE. The unit is
    // named for the state it holds, so active means unbound.
    readonly property bool kbdDisabled: shared.kbdDisabled === true

    function publish(isDisabled) {
        PluginService.setGlobalVar(pluginId, "kbdDisabled", isDisabled);
        PluginService.setGlobalVar(pluginId, "known", true);
    }

    Process {
        id: statusProcess
        command: ["systemctl", "is-active", "--quiet", root.unit]
        running: false
        onExited: exitCode => root.publish(exitCode === 0)
    }

    function refresh() {
        if (!statusProcess.running)
            statusProcess.running = true;
    }

    // Toggle off the unit's real state rather than the cached one, so a unit
    // started or stopped outside the shell cannot desync the button.
    Process {
        id: toggleProcess
        command: ["sh", "-c", 'if systemctl is-active --quiet "$1"; then systemctl stop "$1" && echo on; else systemctl start "$1" && echo off; fi', "sh", root.unit]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                if (t !== "on" && t !== "off") {
                    // Most likely polkit refused: the rule in
                    // features/embedded-keyboard/nixos.nix covers exactly this
                    // unit for the local active session and nothing else.
                    ToastService.showError("Embedded Keyboard", "Could not change state");
                    root.refresh();
                    return;
                }
                const disabled = t === "off";
                root.publish(disabled);
                ToastService.showInfo("Embedded Keyboard", disabled ? "Built-in keyboard disabled" : "Built-in keyboard restored");
                verifyTimer.restart();
            }
        }
    }

    Timer {
        id: verifyTimer
        interval: 500
        onTriggered: root.refresh()
    }

    // Catches changes made outside the shell, including the restore that a
    // reboot performs for free (the unit is not wantedBy anything).
    Timer {
        interval: 10000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    ccWidgetIcon: kbdDisabled ? "keyboard_off" : "keyboard"
    ccWidgetPrimaryText: "Embedded Keyboard"
    ccWidgetSecondaryText: !known ? "..." : (kbdDisabled ? "Disabled" : "On")
    ccWidgetIsActive: kbdDisabled

    onCcWidgetToggled: {
        if (!toggleProcess.running)
            toggleProcess.running = true;
    }
}
