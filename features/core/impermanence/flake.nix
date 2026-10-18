{
  description = "impermanence: the persistence half of an ephemeral root (environment.persistence)";

  /*
    Same two-level follows as feat-agenix: this flake declares a `nixpkgs` only
    so the wrapped input has one to follow, and the parent points it at the
    host's own:

      feat-impermanence = { url = "path:./features/core/impermanence"; inputs.nixpkgs.follows = "nixpkgs"; };

    nix-community/impermanence is NOT in nixpkgs. Only its NixOS module is used
    (environment.persistence for system paths); user homes are persisted by
    this feature's own boot unit from per-user lists (nixos.nix), because a
    user's list lives in their home repo, which the system never evaluates.
  */
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
      # Its home-manager input only serves its home-manager module, unused here.
      inputs.home-manager.follows = "";
    };
  };

  outputs =
    { impermanence, ... }:
    {
      nixosModule = impermanence.nixosModules.impermanence;
    };
}
