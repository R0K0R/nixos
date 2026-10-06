import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

/*
  DankBar는 바마다 이 컴포넌트를 따로 만든다 (main + compact 두 개).
  예전에는 인스턴스마다 자기 `active`를 들고 있어서, 가로 모드에서 켠 뒤
  세로로 돌리면 compact 바의 인스턴스는 "Off"를 보여주면서 inhibitor는 계속
  살아 있었다. 그 상태에서 켜고 끄면(두 번째 inhibitor를 띄우고 pkill로
  전부 죽임) 다시 맞아떨어졌던 것.

  그래서:
    - 상태는 PluginService 전역 변수 하나를 모든 인스턴스가 공유한다.
    - 토글은 로컬 값을 뒤집지 않고, 실제로 inhibitor가 떠 있는지 보고
      켜거나 끈 다음 다시 확인한다.
    - 밖에서 죽거나 떠도 어긋나지 않게 주기적으로 다시 확인한다.
*/
PluginComponent {
    id: root

    // systemd-inhibit 자신만 잡는다. `-f "DMS No Sleep plugin"`만 쓰면
    // 띄우는 중인 sh 래퍼나 다른 인스턴스의 pkill까지 걸린다.
    readonly property string pattern: "^systemd-inhibit .*--who=DMS No Sleep plugin"

    readonly property var shared: PluginService.globalVars[pluginId] || ({})
    readonly property bool known: shared.known === true
    readonly property bool active: shared.active === true

    function publish(isActive) {
        PluginService.setGlobalVar(pluginId, "active", isActive);
        PluginService.setGlobalVar(pluginId, "known", true);
    }

    // 1. 현재 systemd-inhibit이 떠있는지 확인
    Process {
        id: statusProcess
        command: ["pgrep", "-f", root.pattern]
        running: false
        onExited: exitCode => root.publish(exitCode === 0)
    }

    function refresh() {
        if (!statusProcess.running)
            statusProcess.running = true;
    }

    // 2. 토글: 실제 상태를 보고 켜거나 끈다. 켤 때는 setsid로 완전히 떼어내서
    //    DMS가 재시작돼도 살아남게 한다. 끝나면 결과를 "on"/"off"로 출력.
    Process {
        id: toggleProcess
        command: ["sh", "-c", 'if pgrep -f "$1" >/dev/null; then pkill -f "$1"; echo off; '
            + 'else shift; setsid "$@" </dev/null >/dev/null 2>&1 & echo on; fi', "sh", root.pattern, "systemd-inhibit", "--what=idle:sleep:handle-lid-switch", "--who=DMS No Sleep plugin", "--why=User requested", "--mode=block", "sleep", "infinity"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const on = text.trim() === "on";
                root.publish(on);
                ToastService.showInfo("No Sleep", on ? "Suspend blocked" : "Suspend re-enabled");
                // pkill/setsid가 실제로 반영됐는지 잠시 뒤 다시 확인
                verifyTimer.restart();
            }
        }
    }

    Timer {
        id: verifyTimer
        interval: 500
        onTriggered: root.refresh()
    }

    // 3. 밖에서 바뀐 경우 대비. pgrep 하나라 부담 없음.
    Timer {
        interval: 10000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    ccWidgetIcon: "coffee"
    ccWidgetPrimaryText: "No Sleep"
    ccWidgetSecondaryText: !known ? "..." : (active ? "Suspend blocked" : "Off")
    ccWidgetIsActive: active

    onCcWidgetToggled: {
        if (!toggleProcess.running)
            toggleProcess.running = true;
    }

    Component.onCompleted: refresh()
}
