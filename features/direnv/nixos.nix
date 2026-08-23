{ config, lib, ... }:

let
  cfg = config.my.direnv;
in
{
  options.my.direnv = {
    enable = lib.mkEnableOption ''
      direnv with the nix-direnv integration: `use flake` in a project's
      .envrc drops you into its devShell on cd, and caches the result so the
      second entry is instant rather than a re-evaluation
    '';
  };

  # Accounts this feature applies to; defaults to the primary user.
  options.my.direnv.users = import ../../lib/user-scope.nix { inherit lib config; };

  /*
    No packages.nix: home-manager's programs.direnv installs direnv and
    nix-direnv itself, from its own module. Adding them to a package list too
    would install a SECOND copy that the shell hook does not point at -- the
    hook is generated against `programs.direnv.package`, so the two could drift
    to different versions with no error, and the one on PATH would be the one
    not being used.
  */
  config = lib.mkIf cfg.enable {
    /*
      Host-wide even though the feature is per-user scoped, because these are
      nix-daemon settings and the daemon is not per-user. If anyone on the
      machine uses nix-direnv, the store has to behave this way for everyone.

      WHY THESE TWO, specifically: nix-direnv keeps a devShell alive by rooting
      it through a profile in .direnv/. That root names the DERIVATION, and
      without keep-derivations the .drv is collectable, which orphans the root;
      without keep-outputs the built shell inputs go even while the .drv stays.
      Either way `cd` into the project re-realises the whole devShell, which is
      exactly the cost direnv existed to remove.

      Latent rather than urgent HERE: my.nix-settings.gc.automatic is false on
      this machine by deliberate policy (the pseudo-cross store is expensive to
      reproduce). But a manual `nix-collect-garbage` still collects, and the
      note in nix-settings says automatic GC comes back once the store stops
      being expensive -- at which point an unset keep-outputs would quietly
      start deleting dev shells every week.
    */
    nix.settings.keep-outputs = true;
    nix.settings.keep-derivations = true;
  };
}
