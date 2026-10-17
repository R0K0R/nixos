{
  description = "Home configuration: standalone home-manager on top of the system flake";

  inputs = {
    # The system flake. Its homeLib.<host> hands out the host's own pkgs, the
    # feature home modules and the facts, so this repo pins nothing else: no
    # nixpkgs, no home-manager -- a second nixpkgs here would be a second,
    # untuned package set and rebuild everything the system already has.
    # A local checkout works too: "git+file:///home/<you>/flakes/nixos".
    system.url = "github:R0K0R/nixos";
  };

  outputs =
    { self, system }:
    let
      # Set this. It must exist in the system's registry/users/.
      username = "CHANGEME";

      inherit (system.registry) hosts;
      myHosts = builtins.filter (h: builtins.elem username hosts.hosts.${h}.users) (
        builtins.attrNames hosts.hosts
      );
    in
    {
      /*
        One configuration per host this user lives on, named the way
        `home-manager switch --flake .` looks them up: "<user>@<hostname>".

        mkHome builds the SAME home the system's integrated home-manager does
        for this user plus ./modules. asSubmodule follows your registry
        homeActivation: true (identical to the integrated home) while the
        system activates it, false once your file says "standalone", so
        home.packages go to your own profile.
      */
      homeConfigurations = builtins.listToAttrs (
        map (host: {
          name = "${username}@${host}";
          value = system.homeLib.${host}.mkHome {
            inherit username;
            # Add system.homeLib.${host}.epochModule here to record the
            # system epoch in each generation ($generation/epoch), which
            # hm-rollback and the system's session-epoch-check read. It
            # changes the activation package, hence opt-in.
            modules = [ ./modules ];
          };
        }) myHosts
      );
    };
}
