{ config, lib, ... }:

let
  cfg = config.my.direnv;
in
{
  /*
    The SYSTEM half of direnv: only the nix-daemon settings nix-direnv needs.
    direnv itself, its hook and its config are a home feature (r0k0r's home
    repo, features/dev/direnv) since 2026-10-26. A host turns this on when
    anyone on it uses nix-direnv.
  */
  options.my.direnv.enable = lib.mkEnableOption ''
    the nix-daemon settings nix-direnv relies on (keep-outputs,
    keep-derivations); direnv itself is a home feature
  '';

  config = lib.mkIf cfg.enable {
    /*
      Host-wide, because these are nix-daemon settings and the daemon is not
      per-user. If anyone on the machine uses nix-direnv, the store has to behave this way for everyone.

      WHY THESE TWO, specifically: nix-direnv keeps a devShell alive by rooting
      it through a profile in .direnv/. That root names the DERIVATION, and
      without keep-derivations the .drv is collectable, which orphans the root;
      without keep-outputs the built shell inputs go even while the .drv stays.
      Either way `cd` into the project re-realises the whole devShell, which is
      exactly the cost direnv existed to remove.

      Latent rather than urgent HERE: my.nix-settings.gc.automatic is false on
      this machine by deliberate policy (the IntraISACross store is expensive to
      reproduce). But a manual `nix-collect-garbage` still collects, and the
      note in nix-settings says automatic GC comes back once the store stops
      being expensive -- at which point an unset keep-outputs would quietly
      start deleting dev shells every week.
    */
    nix.settings.keep-outputs = true;
    nix.settings.keep-derivations = true;
  };
}
