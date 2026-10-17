/*
  The ONE generator of a home-manager user's configuration, used by both ways a
  home gets built:

    integrated  lib/home-manager.nix, inside a NixOS evaluation
                (home-manager.users.<name>), which is what hosts activate today;
    standalone  homeLib.<host>.mkHome (flake.nix), what a user's own home repo
                calls to get homeConfigurations."<user>@<host>".

  They used to be one hand-written module, and a second copy of it is exactly
  how the earlier bug (lib/home-manager.nix's header) happened: two callers,
  two answers. So everything per-user -- stateVersion today, whatever comes
  next -- is `userModule`, and both paths apply it.

  WHAT STANDALONE HAS TO REPRODUCE, and why it does not call home-manager's own
  homeManagerConfiguration: that entry point always includes HM's nixpkgs
  module and re-imports nixpkgs from `pkgs.path` with only `system` set. On an
  IntraISACross host the package set is a cross set (buildPlatform !=
  hostPlatform), so the re-import would be a different, untuned nixpkgs and a
  different home -- every package rebuilt. Instead mkHome evaluates the same
  module list the NixOS integration does (hm nixos/common.nix's hmModule):
  modules.nix with useNixpkgsModule = !useGlobalPkgs, the same specialArgs
  (lib = HM's extended lib, osConfig, osClass, modulesPath, plus
  extraSpecialArgs incl. nixosConfig), the same sharedModules, and the same
  per-user glue (submoduleSupport, username/homeDirectory/uid from
  users.users, nix.enable/package from the system).

  `asSubmodule` (default: true for homeActivation = "system", false for
  "standalone") keeps that glue's submoduleSupport half:
  externalPackageInstall means home.packages are installed by the SYSTEM via
  users.users.<name>.packages, and activation does not touch a nix profile.
  That is what makes the activation package byte-identical to the integrated
  one, which is the property to keep while both paths coexist. A standalone
  account (the system no longer integrates its home) gets false: packages
  then go into the user's own profile, as a real standalone install needs,
  and the activation package necessarily differs.
*/
{ homeModules, inputs, hostName }:

let
  # ./home-tuning.nix declares the home's my.tuning (per-user tuning); in every
  # home so a user module may always set it.
  sharedModules = homeModules ++ [
    inputs.feat-emacs.homeModule
    ./home-tuning.nix
  ];
  extraSpecialArgs = { inherit inputs hostName; };

  userModule = u: { home.stateVersion = u.stateVersion; };

  /*
    Which my.users get a home at all. Takes lib and the NixOS config rather
    than closing over them so both callers can hand theirs in.
  */
  homeUsers = lib: osConfig: lib.filterAttrs (_: u: u.home) osConfig.my.users;

  /*
    THE CUTOVER, per user. Only homeActivation = "system" accounts become
    home-manager.users.<name> (activated by every system switch). A
    "standalone" account's home is activated by its own repo through
    mkHome, and the system merely evaluates it for the tuning classifier
    (tuning/runtime-cache/tier2-eval.nix, `standaloneHomes`).
  */
  systemUsers = lib: osConfig: lib.filterAttrs (_: u: u.homeActivation == "system") (homeUsers lib osConfig);
  standaloneUsers = lib: osConfig: lib.filterAttrs (_: u: u.homeActivation == "standalone") (homeUsers lib osConfig);
in
{
  inherit sharedModules extraSpecialArgs userModule homeUsers systemUsers standaloneUsers;

  /*
    An integrated home is built from the system's set by the system, so its
    my.tuning must stay at the defaults; per-user tuning is for standalone
    homes (homeLib.<host>.mkHome).
  */
  users =
    lib: osConfig:
    lib.mapAttrs (
      n: u: {
        imports = [
          (userModule u)
          (
            { config, ... }:
            {
              assertions = [
                {
                  assertion =
                    let
                      t = config.my.tuning;
                    in
                    t.march == "system"
                    && t.lto == "system"
                    && t.o3 == "system"
                    && t.packages.o3 ++ t.packages.lto ++ t.exclude.o3 ++ t.exclude.lto == [ ];
                  message = "my.tuning in ${n}'s home: an integrated home (homeActivation = \"system\") is built from the system's package set; per-user tuning needs homeActivation = \"standalone\".";
                }
              ];
            }
          )
        ];
      }
    ) (systemUsers lib osConfig);

  mkHome =
    {
      # The host's evaluated NixOS configuration (nixosConfigurations.<host>).
      nixos,
      username,
      modules ? [ ],
      # my.tuning (the home's own option) -> the package set the home is built
      # from. homeLib.<host>.mkHome passes lib/user-tuning.nix's; without it
      # (tier2-eval's system-side evaluation) a home always gets the host's.
      pkgsFor ? (_: nixos.pkgs),
      # config -> extra failure messages (homeLib's surface compatibility
      # check, lib/surface-check.nix); reported like failed assertions.
      extraChecks ? (_: [ ]),
      # Default follows who activates the home: true (system-installed
      # packages, identical to the integrated home) for "system" accounts,
      # false (packages in the user's own profile) for "standalone" ones.
      asSubmodule ? null,
    }:
    let
      hm = inputs.home-manager;
      osConfig = nixos.config;
      # The HOST's set: home-manager's module list itself (pkgs.path for its
      # assertions/meta modules) and the default _module.args.pkgs, which the
      # tuning module below overrides.
      inherit (nixos) pkgs;
      lib = nixos.lib or pkgs.lib;
      cfg = osConfig.home-manager;
      extendedLib = import "${hm}/modules/lib/stdlib-extended.nix" lib;

      u =
        (homeUsers lib osConfig).${username} or (throw ''
          homeLib.${hostName}.mkHome: "${username}" has no home on ${hostName}
          (not in registry/hosts.nix for this host, or its session is not home-manager).'');
      submodule = if asSubmodule == null then u.homeActivation == "system" else asSubmodule;

      # nixos/common.nix's per-user glue, verbatim apart from the switch.
      glue = {
        submoduleSupport = lib.mkIf submodule {
          enable = true;
          externalPackageInstall = cfg.useUserPackages;
        };
        home = {
          uid =
            let
              userUid = builtins.tryEval osConfig.users.users.${username}.uid;
            in
            lib.mkIf (userUid.success && userUid.value != null) userUid.value;
          username = osConfig.users.users.${username}.name;
          homeDirectory = osConfig.users.users.${username}.home;
        };
        nix = {
          enable = osConfig.nix.enable;
          package = lib.mkIf osConfig.nix.enable osConfig.nix.package;
        };
      };

      raw = extendedLib.evalModules {
        class = "homeManager";
        specialArgs = {
          lib = extendedLib;
          inherit osConfig;
          osClass = "nixos";
          modulesPath = toString "${hm}/modules";
        }
        # The system's final value, not ours: it also carries nixosConfig
        # (added by HM's nixos module) and anything other NixOS modules add.
        // cfg.extraSpecialArgs;
        modules =
          import "${hm}/modules/modules.nix" {
            inherit pkgs;
            lib = extendedLib;
            inherit (cfg) minimal;
            useNixpkgsModule = !cfg.useGlobalPkgs;
          }
          /*
            The system's final sharedModules: ours (`sharedModules` above) plus
            what other NixOS modules inject -- features/niri's upstream module
            adds its own home modules there and they are reachable nowhere
            else. Transitional, like osConfig itself.
          */
          ++ cfg.sharedModules
          ++ [
            { _module.args.name = lib.mkOptionDefault username; }
            # The home's package set from its own my.tuning. Normal priority
            # beats home-manager's `_module.args.pkgs = mkDefault pkgs`; the
            # same fixpoint home-manager's nixpkgs module relies on.
            ({ config, ... }: { _module.args.pkgs = pkgsFor config.my.tuning; })
            glue
            (userModule u)
          ]
          ++ modules;
      };

      failed = map (x: x.message) (lib.filter (x: !x.assertion) raw.config.assertions) ++ extraChecks raw.config;
      checked =
        if failed == [ ] then
          raw
        else
          throw "homeLib.${hostName}.mkHome ${username}: failed assertions:\n${
            lib.concatMapStrings (m: "- ${m}\n") failed
          }";
    in
    checked
    // {
      inherit (checked.config.home) activationPackage;
      # The set this home was actually built from.
      pkgs = checked._module.args.pkgs;
    };
}
