{
  description = "Benjamin's home: standalone home-manager on top of the system flake (the bonfire desktop)";

  inputs = {
    /*
      The system flake. Its homeLib.<host> hands out the host's own pkgs, the
      feature home modules and the facts, so this repo pins no nixpkgs and no
      home-manager of its own: a second nixpkgs here would be a second package
      set and rebuild everything the system already has. The default branch:
      the multiuser work, which exports homeLib, became main on 2026-10-24.
    */
    system.url = "github:R0K0R/nixos";

    /*
      Everything below is a USER-level input: a program or config that only this home consumes,
      so the system flake does not carry its pin. They used to live in the old flake's per-feature
      sub-flakes (features/<name>/flake.nix).
    */

    /*
      bonfire -- the desktop shell (waybar/rofi/swaync + its script suite), our fork
      of the unmaintained R0K0R/hakuspace, fully rebranded (see REBRAND.md). The
      declarative half -- packages.bonfire and homeModules.bonfire -- lives there: the
      package wraps the scripts' deps onto PATH and the home-manager module links
      the tree into ~/.config.

      A BRANCH/COMMIT REF, NOT A LOCAL PATH: `path:` inputs lock with no narHash and
      no revision, so the flake evaluates differently -- or not at all -- on any
      machine where that directory is missing, which is exactly the property a
      lock file exists to prevent.

      nixpkgs is a LOCK-SLIMMING placeholder only. It does NOT decide what the
      package is built against: modules/desktop/bonfire overrides programs.bonfire.package
      with a host-pkgs callPackage, precisely because the flake default (self.packages,
      evaluated on this input's nixpkgs) would build against a different package set
      than the one the rest of the home runs. The follows exists so the lock does not
      pin, and evaluation does not fetch, the nixos-26.05 the shell's own flake
      declares for its standalone use. It follows the system's plain upstream
      nixpkgs, not a second pin.
    */
    bonfire = {
      url = "github:sihooleebd/bonfire";
      inputs.nixpkgs.follows = "system/nixpkgs-upstream";
    };

    /*
      The four below deliberately do NOT follow the system's nixpkgs: each is the author's
      own program, built against its own pin so that its binary cache applies, rather than
      forced onto another nixpkgs and rebuilt.
    */

    # Sonora, consumed as a plain prebuilt package (packages.<system>.default).
    # Benjamin's bugfixed fork (same app: binary + app-id stay "sonora", so the dock route and the
    # my.pyre app-class references are unchanged -- only the source moves).
    sonora.url = "github:sihooleebd/sononora/feat/niche-fixes-and-features";

    # late.sh CLI (mpiorowski/late-sh) -- the `late` companion CLI, consumed from the project's own
    # flake (packages.<system>.late). Builds from source so it links + runs here (no nix-ld), unlike
    # the curl|bash installer's prebuilt binary.
    late-sh.url = "github:mpiorowski/late-sh";

    # lyre -- my headless per-app/per-output EQ + routing engine for PipeWire (the instrument played
    # by the bonfire; replaces EasyEffects; the notif-centre Sound menu is its only UI, driving it over
    # a CLI). Source dev'd in ~/Documents/projects/lyre.
    lyre.url = "github:sihooleebd/lyre";

    # hearth -- generic schema-driven settings store + change-diff signal (the engine behind the
    # unified settings system; see SETTINGS.md). modules/desktop/settings.nix generates its schema
    # from the fragments the other modules contribute. Source dev'd in ~/Documents/projects/hearth.
    hearth.url = "github:sihooleebd/hearth";

    /*
      His own Doom config (the former ~/.doom.d), a plain source tree. Used instead of the
      system's Doom directory when my.ownDoomConfig.enable is set; the Emacs build and
      Unstraightened (the pipeline that turns a Doom directory into Nix derivations) stay the
      system's.
    */
    doom-private = {
      url = "github:sihooleebd/doom-emacs";
      flake = false;
    };
  };

  outputs =
    { self, system, bonfire, ... }@inputs:
    let
      username = "benjamin";

      inherit (system.registry) hosts;
      # Every host the system's registry/hosts.nix puts benjamin on. Today:
      # victus-15 and dell-latitude.
      myHosts = builtins.filter (h: builtins.elem username hosts.hosts.${h}.users) (
        builtins.attrNames hosts.hosts
      );

      /*
        This repo's own inputs, as a module argument named `userInputs` --
        NOT `inputs`, which the system's feature home halves already receive
        (the SYSTEM flake's inputs, via extraSpecialArgs) and still depend on.
      */
      argsModule = {
        _module.args.userInputs = inputs;
      };

      hostModule =
        host:
        let
          p = ./hosts + "/${host}.nix";
        in
        if builtins.pathExists p then [ p ] else [ ];
    in
    {
      /*
        "<user>@<hostname>", the name `home-manager switch --flake .` looks up.

        This repo activates the home (registry homeActivation = "standalone"),
        so mkHome's asSubmodule defaults to false: home.packages go into this
        user's own profile. See README.md.
      */
      homeConfigurations = builtins.listToAttrs (
        map (host: {
          name = "${username}@${host}";
          value = system.homeLib.${host}.mkHome {
            inherit username;
            modules = [
              argsModule
              # programs.bonfire (the upstream home-manager module). Imported here and not in
              # modules/desktop/bonfire because `imports` resolves before module arguments exist,
              # so a module cannot name userInputs there. It only declares options.
              bonfire.homeModules.bonfire
              ./modules
              # This repo's feature tree: features/<category>/<feature>/home.nix,
              # collected like the system's (system.lib.homeFeatures). kitty,
              # starship, eza, the cursor theme and the ssh config, which the
              # system's dell-latitude used to give this home (2026-10-26).
              (system.lib.homeFeatures ./features)
            ]
            ++ hostModule host;
          };
        }) myHosts
      );
    };
}
