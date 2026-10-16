{
  description = "Doom Emacs, built as real Nix derivations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    /*
      Builds Doom as real Nix derivations instead of straight.el's imperative
      git-clone/pull. Its own doomemacs/doomemacs-modules sub-inputs are left
      un-`follows`'d on purpose: ride the framework version it is actually
      tested against, rather than hand-managing version skew -- the exact bug
      class this replaced.
    */
    nix-doom-emacs-unstraightened = {
      url = "github:marienz/nix-doom-emacs-unstraightened";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Former ~/.doom.d (https://github.com/R0K0R/doom-emacs).
    doom-private = {
      url = "github:R0K0R/doom-emacs";
      flake = false;
    };
  };

  outputs =
    { nix-doom-emacs-unstraightened, doom-private, ... }:
    let
      unstraightened = nix-doom-emacs-unstraightened;
      doomscript = "${unstraightened}/build-helpers/doomscript.nix";

      /*
        Unstraightened's import-from-derivation -- `doom-intermediates` (Doom's
        CLI dumping the package list) and one `<pkg>-deps` per pinned package
        (print-deps.el) -- runs the SAME Emacs as the final build. Here that is
        the IntraISACross-tuned Emacs, so whenever the toolchain moved, evaluation
        had to build tuned Emacs and its whole closure before it could finish.

        Both only run Emacs as a script interpreter; their output does not depend
        on compiler flags. With `ifdPackages` set, those helpers come from that
        package set instead (Emacs, runCommandLocal, the doomscript wrapper's
        shell and git), so they substitute from cache.nixos.org. Nothing else
        changes: the elisp packages and the final Emacs still use `emacs`.
        No source patch -- `callPackages` lets these args override the
        package-set ones, and only the two IFD call sites use them.
      */
      ifdArgs =
        ifdPackages: ifdEmacs: pkgs: args:
        let
          swap =
            env:
            env
            // ifdPackages.lib.optionalAttrs (env ? emacs) { emacs = ifdPackages.lib.getExe ifdEmacs; }
            // ifdPackages.lib.optionalAttrs (env ? EMACS) { EMACS = ifdPackages.lib.getExe ifdEmacs; }
            // ifdPackages.lib.optionalAttrs (env ? runtimeShell) { inherit (ifdPackages) runtimeShell; };
        in
        args
        // {
          # default.nix uses runCommandLocal only for "<pkg>-deps" and "tangled-doomdir".
          runCommandLocal = name: env: ifdPackages.runCommandLocal name (swap env);
          # ...and callPackage only for doomscript.nix (doom-intermediates).
          callPackage =
            fn: a:
            if toString fn == doomscript then
              ifdPackages.callPackage fn (a // { emacs = ifdEmacs; })
            else
              pkgs.callPackage fn a;
        };
    in
    {
      homeModule =
        { config, lib, ... }:
        let
          cfg = config.programs.doom-emacs;
          ifdEmacs = if cfg.ifdEmacs != null then cfg.ifdEmacs else cfg.ifdPackages.emacs-nox;
        in
        {
          imports = [
            (import "${unstraightened}/home-manager.nix" {
              doomFromPackages =
                pkgs: args:
                unstraightened.lib.doomFromPackages pkgs (
                  if cfg.ifdPackages == null then args else ifdArgs cfg.ifdPackages ifdEmacs pkgs args
                );
              doomDirInput = unstraightened.inputs.doomdir;
            })
          ];

          options.programs.doom-emacs = {
            ifdPackages = lib.mkOption {
              type = lib.types.nullOr lib.types.raw;
              default = null;
              description = ''
                Package set for unstraightened's evaluation-time helpers (its
                import-from-derivation). null: the same packages as the build.
              '';
            };
            ifdEmacs = lib.mkOption {
              type = lib.types.nullOr lib.types.package;
              default = null;
              description = "Emacs for those helpers; null: ifdPackages.emacs-nox.";
            };
          };

          # Same Emacs VERSION, or Doom's builtin-packages list (and so which packages
          # it pins) could differ from what the real Emacs ships.
          config.assertions = lib.mkIf (cfg.enable && cfg.ifdPackages != null) [
            {
              assertion = lib.versions.majorMinor ifdEmacs.version == lib.versions.majorMinor cfg.emacs.version;
              message = "programs.doom-emacs: ifd Emacs ${ifdEmacs.version} != Emacs ${cfg.emacs.version}; set ifdEmacs to a matching version.";
            }
          ];
        };
      doomDir = doom-private;
    };
}
