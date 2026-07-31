/*
  Keep Doom's compiled artifacts in step with the Emacs binary Nix builds.

  WHY THIS IS NEEDED AT ALL
  -------------------------
  `doom sync` already rebuilds when it detects an Emacs *version* change. It
  cannot detect ours: Straight keys its build tree on the version alone
  (.local/straight/build-30.2), so an Emacs rebuilt from 30.2 to 30.2 with a
  different toolchain -- a new store path, same version string -- looks
  identical to Doom while every .elc in that tree is stale against the new
  binary. Observed 2026-07-29: emacs-pgtk was rebuilt at 01:24, straight's
  build-30.2 was 13 days old, and doom-themes' treemacs extension silently
  failed to register despite the .el being present on disk.

  So the store path is the trigger, and the rebuild has to be forced with `-b`;
  plain `doom sync` would decide there was nothing to do.

  WHY A SERVICE RATHER THAN AN ACTIVATION SCRIPT
  ----------------------------------------------
  home-manager-<user>.service is Type=oneshot with TimeoutStartSec=5m. A
  `doom sync -b` across 239 packages does not reliably fit in that, and being
  SIGKILLed halfway leaves Doom in a worse state than the staleness we set out
  to fix. A separate unit gets its own (generous) timeout, survives the switch,
  and logs to the journal where a failure is visible rather than silent.

  Activation only fires the trigger, with --no-block, so a switch is never held
  up by a sync.

  FAILURE SEMANTICS
  -----------------
  The stamp is written by the service *after* a successful sync, never by the
  activation script. A sync that fails, is killed, or never starts leaves the
  stamp stale, so the next switch tries again. There is no state in which we
  believe a sync happened that did not.
*/
{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:

let
  emacsEnv = import ./env.nix { inherit pkgs inputs; };
  inherit (emacsEnv) emacsRolling vtermInstallScript;

  emacsd = "${config.home.homeDirectory}/.emacs.d";
  stamp = "${emacsd}/.local/.nix-doom-stamp";

  /*
    Everything whose change invalidates Straight's build tree. Emacs first and
    space-separated, because the script compares field 1 on its own to decide
    between a plain sync and a forced rebuild.
  */
  syncIdentity = "${emacsRolling} ${inputs.doom-emacs} ${inputs.doom-private}";

  doomSyncScript = pkgs.writeShellScript "doom-sync-if-stale" ''
    set -uo pipefail

    doom="${emacsd}/bin/doom"
    stamp="${stamp}"
    want="${syncIdentity}"

    if [[ ! -x "$doom" ]]; then
      echo "doom-sync: no executable at $doom; run home activation first" >&2
      exit 0
    fi

    have=""
    [[ -r "$stamp" ]] && have="$(cat "$stamp")"
    if [[ "$have" == "$want" ]]; then
      echo "doom-sync: up to date, nothing to do"
      exit 0
    fi

    # Straight's build tree is keyed on Emacs version, so a same-version rebuild
    # needs -b to force it. Config-only changes do not.
    rebuild=()
    prev_emacs="''${have%% *}"
    if [[ "$prev_emacs" != "${emacsRolling}" ]]; then
      echo "doom-sync: emacs changed (''${prev_emacs:-none} -> ${emacsRolling}), forcing rebuild"
      rebuild=(-b)
    fi

    export PATH="${
      lib.makeBinPath [
        emacsRolling
        pkgs.git
        pkgs.gnutar
        pkgs.gzip
        pkgs.findutils
        pkgs.ripgrep
        pkgs.fd
        pkgs.gcc
      ]
    }:$PATH"
    export EMACSDIR="${emacsd}"
    export DOOMDIR="${config.xdg.configHome}/doom"

    # --force: activation has no tty, so prompts would hang until the timeout.
    if ! "$doom" sync --force "''${rebuild[@]}"; then
      echo "doom-sync: sync FAILED; leaving stamp stale so the next switch retries" >&2
      exit 1
    fi

    # doom sync rebuilds build-<ver>/, discarding the module activation installed.
    ${vtermInstallScript} "${emacsd}"

    printf '%s' "$want" > "$stamp"
    echo "doom-sync: done"

    # try-restart, not restart: does nothing if the daemon was never running,
    # which is the case on a switch from a tty with no graphical session.
    #
    # --no-block is load-bearing, not an optimization: emacs.service has
    # Before=emacs.service on THIS unit (see below), so systemd will not
    # dispatch emacs.service's restart job until doom-sync.service's own job
    # finishes. A blocking try-restart called from inside that job waits on a
    # job that is itself waiting on this call to return -- a self-deadlock.
    # Observed 2026-07-31: stuck "activating" for 2+ hours after a switch that
    # rebuilt emacs-pgtk, with the daemon already dead and no way to reach it
    # short of killing this call by hand. The stamp write above already
    # completed by the time we get here, so there is nothing left to block on.
    ${lib.getExe' pkgs.systemd "systemctl"} --user try-restart --no-block emacs.service || true
  '';
in
{
  systemd.user.services.doom-sync = {
    Unit = {
      Description = "Rebuild Doom Emacs packages when the Nix-built Emacs changes";
      # Ordering only -- no Wants/Requires, so this never drags emacs.service up
      # on a machine where the daemon is deliberately stopped.
      Before = [ "emacs.service" ];
    };

    Service = {
      Type = "oneshot";
      ExecStart = "${doomSyncScript}";
      # Native compilation across 239 packages is unbounded in practice; the
      # point of splitting this out of activation was to escape a 5m ceiling,
      # so do not reintroduce one.
      TimeoutStartSec = "infinity";
      # Keep the machine usable while this grinds; it is never latency-critical.
      Nice = 10;
      IOSchedulingClass = "idle";
    };

    # Deliberately no Install/WantedBy: this is triggered by activation when the
    # stamp is stale, not run unconditionally on every login.
  };

  /*
    "reloadSystemd" is a real dependency, not decoration: the unit has to be
    known to the user manager before we can start it. home-manager currently
    happens to order this entry last anyway, but relying on that is luck.

    No `exit 0` anywhere below. home-manager concatenates every activation
    snippet into one script, so an early exit here would abort the whole
    activation and silently skip any step ordered after it.
  */
  home.activation.triggerDoomSync =
    lib.hm.dag.entryAfter [
      "installNixEmacsVtermIntoStraight"
      "reloadSystemd"
    ]
      ''
        if [[ "$(cat ${stamp} 2>/dev/null)" != "${syncIdentity}" ]]; then
          # --no-block so the switch is not held up. With no user session bus
          # (switching from a tty, or a boot-time activation) this fails
          # harmlessly and the stale stamp makes the next activation retry.
          if ${lib.getExe' pkgs.systemd "systemctl"} --user start --no-block doom-sync.service 2>/dev/null; then
            echo "doom-sync: Emacs or Doom config changed; syncing in the background."
            echo "           follow it with: journalctl --user -fu doom-sync.service"
          else
            echo "doom-sync: no user session bus; will retry next activation." >&2
            echo "           run it by hand with: systemctl --user start doom-sync.service" >&2
          fi
        fi
      '';
}
