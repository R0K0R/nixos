{
  description = "agenix: age-encrypted secrets, decrypted to /run at activation";

  /*
    TWO-LEVEL follows, same as feat-niri and feat-dms: this flake declares its
    own `nixpkgs` purely so the wrapped input has something to follow, and the
    parent points it at the fork:

      # root flake.nix
      feat-agenix = { url = "path:./features/agenix"; inputs.nixpkgs.follows = "nixpkgs"; };

    Miss either half and agenix's CLI and its activation script build against a
    second, unrelated package set -- its own age, its own openssl -- in the
    closure.

    agenix is NOT in nixpkgs (only `age` and `ssh-to-age` are), which is why it
    has to come from its own flake at all.
  */
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      # agenix pulls darwin/home-manager modules it does not need here; both are
      # optional inputs guarded behind their own outputs, so dropping them keeps
      # the lock from carrying two more trees for modules this repo never
      # imports.
      inputs.darwin.follows = "";
      inputs.home-manager.follows = "";
    };
  };

  outputs =
    { agenix, nixpkgs, ... }:
    {
      nixosModule = agenix.nixosModules.default;
      # The `agenix` CLI, for `agenix -e age/<name>.age`. Exposed so the feature
      # can put it in systemPackages without the root flake needing the input.
      packages.x86_64-linux.agenix = agenix.packages.x86_64-linux.default;
    };
}
