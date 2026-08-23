{ config, lib, osConfig, ... }:

let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.direnv.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "direnv"; };
in
lib.mkIf (osConfig.my.direnv.enable && inScope) {
  programs.direnv = {
    enable = true;

    /*
      The reason this feature exists. Plain direnv re-evaluates the flake on
      every `cd` into the directory; nix-direnv adds `use flake`, which caches
      the resulting environment and roots it in .direnv/ so the second entry is
      a file read rather than an evaluation.

      That matters more here than on a stock machine: a devShell evaluated
      against this fork can pull the pseudo-cross package set, and re-doing that
      per shell invocation is exactly the cost worth caching away.
    */
    nix-direnv.enable = true;

    /*
      Shell integrations are left at their defaults (on) -- deliberately unlike
      features/starship, which sets enableFishIntegration = false because
      features/fish hand-writes `starship init fish | source` to control
      ordering against its transient-prompt function. direnv's hook has no such
      ordering requirement, so there is nothing to hand-roll and the generated
      hook is the one to use.
    */

    config.global = {
      /*
        direnv warns when a .envrc takes longer than this, and the default is 5
        SECONDS -- far too short for the first entry into a flake devShell that
        has to build or substitute anything. The warning is harmless but trains
        you to ignore it, which is worse than not printing it.

        Not disabled outright: a devShell that takes over a minute usually
        means something is being rebuilt that should have been cached, and that
        IS worth being told about.
      */
      warn_timeout = "60s";

      /*
        Suppress the full environment diff on entry. A nix devShell replaces
        essentially every variable, so the diff is hundreds of lines on every
        cd -- it scrolls the actual command off screen and communicates
        nothing. direnv still prints its loading/unloading lines, so the fact
        that an environment changed remains visible; only the unreadable part
        is hidden.
      */
      hide_env_diff = true;
    };
  };
}
