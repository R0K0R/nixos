import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root

    property bool active: false
    property bool known: false

    // 1. 현재 systemd-inhibit이 떠있는지 pgrep으로 확인
    Process {
        id: statusProcess
        // --who에 지정했던 이름으로 검색
        command: ["pgrep", "-f", "DMS No Sleep plugin"]
        running: false
        onExited: (exitCode) => {
            root.active = (exitCode === 0)
            root.known = true
        }
    }

    // 2. 켜기: sh + setsid + disown으로 완전히 백그라운드로 떼어내서 실행
    Process {
        id: startProcess
        command: [
            "sh", "-c",
            "setsid \"$@\" </dev/null >/dev/null 2>&1 & disown; exit 0",
            "sh",
            "systemd-inhibit",
            "--what=idle:sleep:handle-lid-switch",
            "--who=DMS No Sleep plugin",
            "--why=User requested",
            "--mode=block",
            "sleep", "infinity"
        ]
        running: false
    }

    // 3. 끄기: pkill로 떼어놓았던 백그라운드 프로세스 찾아 죽이기
    Process {
        id: stopProcess
        command: ["pkill", "-f", "DMS No Sleep plugin"]
        running: false
    }

    ccWidgetIcon: "coffee"
    ccWidgetPrimaryText: "No Sleep"
    ccWidgetSecondaryText: !known ? "..." : (active ? "Suspend blocked" : "Off")
    ccWidgetIsActive: active

    onCcWidgetToggled: {
        active = !active
        if (active) {
            startProcess.running = true
        } else {
            stopProcess.running = true
        }
        ToastService.showInfo("No Sleep", active ? "Suspend blocked" : "Suspend re-enabled")
    }

    Component.onCompleted: {
        statusProcess.running = true
    }
}
