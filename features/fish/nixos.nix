{ config, lib, pkgs, ... }:

let
  cfg = config.my.fish;

  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };

  # Accounts whose LOGIN shell is fish. Matched on pname rather than by
  # comparing derivations, so an overridden or wrapped fish still counts.
  fishLoginUsers = lib.attrNames (
    lib.filterAttrs (_: u: u.shell != null && (u.shell.pname or u.shell.name or "") == "fish") config.my.users
  );
in

{
  options.my.fish.enable = lib.mkEnableOption "the fish shell user config: aliases, abbreviations and interactive init";

  options.my.fish.systemIntegration = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Turn on the NixOS `programs.fish` module, i.e. fish as a SYSTEM shell
      rather than only a home-manager program.

      What this actually buys, since the obvious guess is wrong: it is NOT
      about /etc/shells. NixOS already collects every declared login shell into
      that file on its own (config/users-groups.nix builds `environment.shells`
      from `users.users.<n>.shell`), so `my.users.<n>.shell = pkgs.fish` is a
      valid login shell with or without this option.

      What is genuinely missing without it:

        * VENDOR PATHS. programs.fish adds /share/fish/vendor_conf.d,
          vendor_completions.d and vendor_functions.d to
          environment.pathsToLink. Without them, system packages that ship fish
          completions or conf.d snippets have those files present in their own
          store paths and never linked into the system profile -- so fish never
          sees them. This is the real one, and it fails silently: completions
          are simply absent, which reads as "fish has no completion for this"
          rather than as a misconfiguration.

        * /etc/fish/config.fish, and the fish package in systemPackages.

      NOT enabled by `my.fish.enable`. That switch is the home-manager half --
      a user's aliases, abbreviations and prompt -- and it is legitimate to want
      fish as an interactive shell you invoke by name without making it a system
      shell. Auto-enabling would also make this feature stop describing what the
      machine does, which is the property the whole layout exists to keep.

      COST: programs.fish.generateCompletions defaults to TRUE upstream, which
      generates completions from man pages for every package in
      environment.systemPackages. Measure before assuming it is free; set
      `programs.fish.generateCompletions = false` in the host if it is not
      worth it.
    '';
  };

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/fish/home.nix gates on via osConfig.
  # Accounts this feature applies to; defaults to the primary user.
  options.my.fish.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      my.packages.perUser = lib.genAttrs cfg.users (_: pkgSet.user);
    })

    /*
      mkIf rather than `programs.fish.enable = cfg.systemIntegration`, because
      types.bool merges with mergeEqualOption: a host that also sets
      programs.fish.enable directly would collide with a definition of `false`
      rather than being overridden by it. Only ever assert the true case.
    */
    (lib.mkIf cfg.systemIntegration {
      programs.fish.enable = true;
    })

    /*
      A WARNING, not an assertion, and the distinction is the point: a fish
      login shell without systemIntegration still works. It logs in, it runs,
      it reads its home-manager config. It is DEGRADED -- no vendor completions
      from system packages -- not broken, and features/_meta's assertions are
      for configurations that produce a broken machine.

      Worth saying at all because the degradation is invisible from inside:
      missing completions look like fish not having any for that command.
    */
    {
      warnings = lib.optional (fishLoginUsers != [ ] && !cfg.systemIntegration) ''
        ${lib.concatStringsSep ", " fishLoginUsers} ${
          if lib.length fishLoginUsers == 1 then "has" else "have"
        } fish as a login shell, but my.fish.systemIntegration is false.

        The account works, but fish will not see completions or conf.d snippets
        shipped by system packages -- programs.fish is what links
        /share/fish/vendor_* into the system profile. Set
        my.fish.systemIntegration = true; or, if that is deliberate, this
        warning is the only thing it costs.
      '';
    }
  ];
}
