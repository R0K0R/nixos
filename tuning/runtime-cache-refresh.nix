{ config, lib, pkgs, ... }:

let
  cfg = config.my.tuning.refreshTool;
  self = config.networking.hostName;
  flake = config.my.tuning.flakePath;

  /*
    The shared body of every cache-refresh command. Refreshes, for each host
    named on its command line:

      aliasable  the upstream-tools overlay's attribute walk -- host-independent,
                 so once per run, before any host
      tier2      an eval heuristic; computable for any host from anywhere
      tier1      the host's LIVE system closure -- read locally for this
                 machine, over ssh for another (refresh-tier1.sh TIER1_SSH), or
                 skipped with a message when there is no ssh route to it

    Everything is written into THIS checkout and staged. `git add` at the end is
    load-bearing, not tidiness: a dirty tree's flake evaluation -- what
    nixos-rebuild actually does, without --impure -- only sees files git knows
    about. A cache file git cannot see is written, reported as written, and then
    silently ignored by the rebuild, which falls through to Tier 3 with no error.
    Hit twice: once when the files were new and untracked, and again when they
    were briefly listed in .gitignore (which also made plain `git add` a no-op).
    They are deliberately tracked now -- see the note in .gitignore.

    Tier 1 for this machine must be read here: it captures /run/current-system,
    and a hardcoded name once wrote victus-15's 461-package closure into
    galaxybook4-pro360's cache file. refresh-tier1.sh now also refuses a ssh
    target whose hostname is not the host being filed.
  */
  refresh = pkgs.writeShellScript "cache-refresh-run" ''
    set -euo pipefail
    CACHE_DIR=${flake}/tuning/runtime-cache
    declare -A TARGET=(${lib.concatStrings (lib.mapAttrsToList (h: t: "[${lib.escapeShellArg h}]=${lib.escapeShellArg (if t == null then "" else t)} ") cfg.sshTargets)})

    echo "== aliasable-names cache (host-independent)"
    "$CACHE_DIR/refresh-aliasable.sh"

    for host in "$@"; do
      echo "== $host: tier2"
      "$CACHE_DIR/refresh-tier2.sh" "$host"
      if [ "$host" = "$(hostname)" ]; then
        echo "== $host: tier1 (this machine)"
        "$CACHE_DIR/refresh-tier1.sh" "$host"
      elif [ -n "''${TARGET[$host]:-}" ]; then
        echo "== $host: tier1 over ssh (''${TARGET[$host]})"
        TIER1_SSH="''${TARGET[$host]}" "$CACHE_DIR/refresh-tier1.sh" "$host"
      else
        echo "== $host: tier1 SKIPPED -- no ssh route from $(hostname) (my.tuning.refreshTool.sshTargets);" >&2
        echo "   run cache-refresh-local on $host itself" >&2
      fi
    done

    git -C ${flake} add "$CACHE_DIR"
    echo "staged tuning/runtime-cache -- commit it to persist"
  '';

  command = name: hosts: pkgs.writeShellScriptBin name ''exec ${refresh} ${lib.escapeShellArgs hosts} "$@"'';
in
{
  options.my.tuning.refreshTool = {
    enable = lib.mkEnableOption ''
      the cache-refresh commands, which regenerate the runtime-cache tiers:
      `cache-refresh` (every host in sshTargets), `cache-refresh-local` (this
      machine), and `cache-refresh-<host>` for each host. Wanted on any host that
      participates in the classifier
    '';

    sshTargets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
      default = {
        # The `Host victus-15` entry the remote builder already uses.
        victus-15 = "victus-15";
        # No sshd on the laptop: from victus, its tier1 is skipped (tier2 still runs).
        galaxybook4-pro360 = null;
      };
      description = ''
        Every host the commands know, mapped to the ssh target its Tier 1 is read
        through from OTHER machines (null: no route; Tier 1 for it is then skipped
        everywhere but on itself). This machine's own entry is ignored -- it is
        always read locally.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      [
        (command "cache-refresh" (builtins.attrNames cfg.sshTargets))
        (command "cache-refresh-local" [ self ])
      ]
      ++ map (h: command "cache-refresh-${h}" [ h ]) (builtins.attrNames cfg.sshTargets);
  };
}
