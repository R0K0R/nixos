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

  /*
    Off by default since 2026-11-23. keep-outputs/keep-derivations are store-
    wide, not per-shell: they keep the whole BUILD chain of every live path. On
    galaxybook (tuned world, built remotely, never locally) a GC freed 8.7 GiB
    of a 358.2 GiB store; measured from the database, only 57.6 GiB was needed
    at runtime and 300.6 GiB was kept by these two alone -- 47 clang builds, 250
    gcc, 1565 sources, 82 claude-code versions. The cost of off: a dev shell
    re-fetches its inputs on the first `cd` after a GC; and a host that builds
    for itself loses its toolchain to a GC, which is why this is a choice.
  */
  options.my.direnv.keepShellInputs = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Set keep-outputs and keep-derivations, so a GC keeps nix-direnv dev
      shells' inputs -- and every live path's build chain with them.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.keepShellInputs) {
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
