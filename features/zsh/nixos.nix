{ config, lib, pkgs, ... }:

let
  cfg = config.my.zsh;

  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };

  # Accounts whose LOGIN shell is zsh. Matched on pname rather than by
  # comparing derivations, so an overridden or wrapped zsh still counts.
  zshLoginUsers = lib.attrNames (
    lib.filterAttrs (_: u: u.shell != null && (u.shell.pname or u.shell.name or "") == "zsh") config.my.users
  );
in

{
  options.my.zsh.enable = lib.mkEnableOption "the zsh shell user config: aliases, completion, highlighting and interactive init";

  options.my.zsh.systemIntegration = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Turn on the NixOS `programs.zsh` module, i.e. zsh as a SYSTEM shell
      rather than only a home-manager program. The same reasoning as
      my.fish.systemIntegration applies, with one zsh-specific difference.

      NOT about /etc/shells: NixOS collects every declared login shell into that
      file on its own, so `my.users.<n>.shell = pkgs.zsh` is a valid login shell
      with or without this option.

      What is genuinely missing without it:

        * VENDOR COMPLETIONS. programs.zsh adds /share/zsh to
          environment.pathsToLink, which is what puts system packages'
          site-functions on fpath. Without it those completions sit unreferenced
          in their own store paths and compinit never sees them -- and it fails
          silently, reading as "zsh has no completion for this" rather than as a
          misconfiguration. This is the direct analogue of fish's vendor_* paths.

        * /etc/zshrc and /etc/zshenv, and the zsh package in systemPackages.

      ZSH-SPECIFIC: the NixOS module also owns compinit. programs.zsh.enableCompletion
      runs it system-wide, and home-manager's programs.zsh.enableCompletion runs
      it again per user. Running compinit twice is slow, not broken, so prefer
      leaving the home-manager one on (it is what this feature configures) and
      set programs.zsh.enableCompletion = false in the host if startup time
      matters.
    '';
  };

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/zsh/home.nix gates on via osConfig.
  # Accounts this feature applies to; defaults to the primary user.
  options.my.zsh.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      my.packages.perUser = lib.genAttrs cfg.users (_: pkgSet.user);
    })

    /*
      mkIf rather than `programs.zsh.enable = cfg.systemIntegration`, because
      types.bool merges with mergeEqualOption: a host that also sets
      programs.zsh.enable directly would collide with a definition of `false`
      rather than being overridden by it. Only ever assert the true case.
    */
    (lib.mkIf cfg.systemIntegration {
      programs.zsh.enable = true;
    })

    /*
      A WARNING, not an assertion, for the same reason as fish's: a zsh login
      shell without systemIntegration still works, it is DEGRADED (no vendor
      completions from system packages), and the degradation is invisible from
      inside.
    */
    {
      warnings = lib.optional (zshLoginUsers != [ ] && !cfg.systemIntegration) ''
        ${lib.concatStringsSep ", " zshLoginUsers} ${
          if lib.length zshLoginUsers == 1 then "has" else "have"
        } zsh as a login shell, but my.zsh.systemIntegration is false.

        The account works, but zsh will not see completions shipped by system
        packages -- programs.zsh is what links /share/zsh into the system
        profile, putting their site-functions on fpath. Set
        my.zsh.systemIntegration = true; or, if that is deliberate, this
        warning is the only thing it costs.
      '';
    }
  ];
}
