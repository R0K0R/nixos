{
  description = "DankMaterialShell: the desktop shell, its greeter and its plugin registry";

  /*
    All three of DMS's upstreams, owned by the feature that consumes them. This
    is what the plan meant by giftable: `rm -r features/dms` takes the shell,
    the greeter, the plugin registry and their pins with it, and the root flake
    stops carrying pins for a shell it no longer has.

    Two-level follows -- see features/niri/flake.nix for why both halves are
    required and what goes wrong when one is missing.
  */
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    dms = {
      url = "github:AvengeMedia/DankMaterialShell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The greeter split out of dms itself into its own repo.
    dank-greeter = {
      url = "github:AvengeMedia/dank-greeter";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms-plugin-registry = {
      url = "github:AvengeMedia/dms-plugin-registry";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { dms, dank-greeter, dms-plugin-registry, ... }:
    {
      greeterModule = dank-greeter.nixosModules.default;
      homeModules = [
        dms.homeModules.dank-material-shell
        dms.homeModules.niri
        # dms-plugin-registry split its single `modules` output into
        # homeModules/nixosModules.
        dms-plugin-registry.homeModules.default
      ];
    };
}
