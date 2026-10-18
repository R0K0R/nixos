{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.epoch;
  computed = import ../../../lib/epoch.nix { inherit lib; } config;

  historyDir = "/var/lib/nixos-epochs";
  historyFile = "${historyDir}/history.jsonl";

  /*
    The record baked into the toplevel. A FILE IN THE TOPLEVEL rather than
    only /etc/nixos-epoch: /etc is the current generation's view, while the
    history unit and the boot-menu backfill have to read the epoch of
    generations that are NOT current, and every generation's toplevel is
    reachable from its profile link.
  */
  epochJson = builtins.toJSON {
    inherit (computed) epoch;
    inherit (cfg) rev;
    host = config.networking.hostName;
  };

  /*
    Every script here is plain bash over epoch-lib.sh, with its tools on PATH.
    writeShellScriptBin, not writeShellApplication: the latter's shellcheck
    pass needs ShellCheck built for this package set, i.e. GHC, which on a
    tuned host is not in any cache -- a multi-hour build for a lint.
  */
  mkScript =
    name: deps: body:
    pkgs.writeShellScriptBin name ''
      set -uo pipefail
      export PATH=${
        lib.makeBinPath (
          [
            pkgs.coreutils
            pkgs.jq
            pkgs.gnugrep
            pkgs.findutils
            pkgs.util-linux
          ]
          ++ deps
        )
      }''${PATH:+:$PATH}
      EPOCH_HISTORY=${historyFile}
      . ${./epoch-lib.sh}
      ${body}
    '';

  # The same home-manager the system's integrated module uses and homeLib
  # hands to user repos -- one version for both halves.
  home-manager = pkgs.callPackage "${inputs.home-manager}/home-manager" {
    path = "${inputs.home-manager}";
  };

  hm-switch = mkScript "hm-switch" [ config.nix.package home-manager ] (builtins.readFile ./hm-switch.sh);
  hm-rollback = mkScript "hm-rollback" [ ] (builtins.readFile ./hm-rollback.sh);
  record = mkScript "nixos-epoch-record" [ ] (builtins.readFile ./record.sh);
in
{
  options.my.epoch = {
    enable = lib.mkEnableOption ''
      the system epoch: recorded in the toplevel and /etc/nixos-epoch, logged
      per boot to ${historyFile}, and checked by hm-switch / hm-rollback before
      a user home is switched. config.system.build.epoch and
      my.epoch.surfaceReport evaluate whether or not this is on.

      Under impermanence ${historyDir} must be persisted: a history that
      resets every boot knows only the running revision, and every older
      user lock looks foreign'';

    extraSurface = lib.mkOption {
      type = lib.types.listOf (lib.types.either lib.types.package lib.types.str);
      default = [ ];
      example = lib.literalExpression "[ pkgs.mesa ]";
      description = ''
        Further derivations the system loads into user processes that the
        automatic surface (lib/epoch.nix) cannot see -- a library a wrapper
        LD_PRELOADs, a plugin directory baked into a shared config. Anything
        here moves the epoch whenever its derivation changes.
      '';
    };

    ignoreSurface = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "desktops" ];
      description = ''
        Derivation names (without hash, as the report prints them) that the
        automatic surface reaches but that are not loaded into user processes,
        left out of the epoch and listed under "ignored" in surfaceReport.

        Default: `desktops`, services.displayManager's session-entry
        directory. It reaches XDG_DATA_DIRS, but only a greeter reads
        share/wayland-sessions -- and without the exclusion, adding a session
        (the fallback session itself) would move the epoch and invalidate every
        home generation on the machine for a .desktop file.
      '';
    };

    rev = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = inputs.self.rev or inputs.self.dirtyRev or null;
      defaultText = lib.literalExpression "inputs.self.rev or inputs.self.dirtyRev or null";
      description = ''
        The system flake revision recorded with the epoch. This is what a user's
        flake.lock names (its `system` input's locked rev), so hm-switch can
        map that lock to an epoch without evaluating anything. A "-dirty" rev
        is recorded but never offered by `hm-switch --update`: nobody can lock
        to an uncommitted tree. It also has to be PUSHED to wherever user repos
        fetch the system flake from before a user can lock to it.

        Deliberately not system.configurationRevision: that one feeds
        nixos-version, hence system-path, so every commit would rebuild the
        system's package environment. This is only read into the toplevel.
      '';
    };

    surfaceReport = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = computed.report;
      defaultText = lib.literalMD "computed by lib/epoch.nix";
      description = ''
        What the epoch hashes, by category (env, graphics, pam, nss, locale,
        extra), store path -> { name, via }. `via` names the options that put
        it there, i.e. what to change to take it out of the surface:

          nix eval .#nixosConfigurations.<host>.config.my.epoch.surfaceReport --json
      '';
    };

    historyFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = historyFile;
      description = "The epoch history, one JSON object per line. Fixed: StateDirectory owns it.";
    };

    internal.mkScript = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      default = mkScript;
      description = ''
        name -> [ deps ] -> body -> package: a bash script with epoch-lib.sh
        sourced and the history path set. For features/session/fallback-session.
      '';
    };

    internal.tools = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      default = { inherit hm-switch hm-rollback; };
      description = "hm-switch and hm-rollback, for other features to reuse.";
    };
  };

  config = lib.mkMerge [
    {
      /*
        Always defined: an attribute of system.build costs nothing unless
        read, and it lets homeLib and checks compare epochs of hosts that have
        not turned the feature on yet.
      */
      system.build.epoch = computed.epoch;
      # Depended upon by fallback-session; see features/_meta.
      my.internal.features.epoch.enabledBy = cfg.enable;
      system.build.epochSurfacePaths = computed.paths;
    }

    (lib.mkIf cfg.enable {
      system.systemBuilderCommands = ''
        echo ${lib.escapeShellArg epochJson} > $out/epoch.json
      '';

      environment.etc."nixos-epoch".text = computed.epoch + "\n";
      my.state.system.state.directories = [
        "/var/lib/nixos-epochs" # epoch history that hm-switch --update offers revisions from
      ];

      environment.systemPackages = [
        hm-switch
        hm-rollback
      ];

      /*
        WHY A UNIT THAT READS /run/current-system, AND NOT AN ACTIVATION
        SNIPPET THAT WRITES ITS OWN VALUES.

        1. Activation also runs at boot, but in stage 2 BEFORE local mounts
           beyond / are guaranteed; under impermanence /var/lib/nixos-epochs is
           a bind mount that appears later, so an activation-time append lands
           on the tmpfs and is then shadowed -- the record vanishes silently.
           RequiresMountsFor= orders this after the mount.
        2. Inside the activation script /run/current-system is only flipped
           part-way through; a unit started after switch-to-configuration (or
           at boot) reads the final value. The DATA (epoch.json) lives in each
           toplevel, so reading it through /run/current-system records exactly
           the system user processes now see, whichever way it got there:
           switch, `nixos-rebuild test`, or a boot-menu pick.
        3. Rollbacks. A boot-menu pick of an older generation that HAS this
           feature runs that generation's unit, which records it -- nothing
           depends on the newest generation's code having run. A generation
           that PREDATES the feature has no unit, no epoch.json and no
           hm-switch either, so nothing can record or check it while it runs;
           the next boot of a feature-carrying generation records that one
           again (the "current" line reappears), and the backfill below adds
           any generation sitting in the boot menu -- built with `nixos-rebuild
           boot`, or switched to while this unit was off -- so `hm-switch
           --update` can offer revisions the machine is only one reboot away
           from. Pre-feature generations in the menu are recorded with a null
           epoch, which nothing ever matches.

        restartTriggers: switch-to-configuration restarts a changed unit, and
        the epoch or rev changing is what changes it -- so a switch is
        recorded at once, not at the next boot. (The toplevel itself cannot be
        a trigger: it would contain its own hash.)
      */
      systemd.services.nixos-epoch-record = {
        description = "Record the running system's epoch in ${historyFile}";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        unitConfig.RequiresMountsFor = [ historyDir ];
        restartTriggers = [ computed.epoch (toString cfg.rev) ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${record}/bin/nixos-epoch-record";
          # World-readable: hm-switch runs as the user and reads it.
          StateDirectory = "nixos-epochs";
          StateDirectoryMode = "0755";
        };
      };
    })
  ];
}
