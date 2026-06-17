{ inputs, lib, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Point nix-shell / nix run / the flake registry at the unpatched upstream
  # nixpkgs so derivation hashes match what Hydra cached.  nixpkgs-upstream is
  # a separate input that --override-input nixpkgs path:... never touches.
  # nixpkgs-flake.nix also sets nix.registry.nixpkgs; mkForce wins.
  nix.registry.nixpkgs = lib.mkForce { flake = inputs.nixpkgs-upstream; };
  nix.nixPath = lib.mkForce [ "nixpkgs=${inputs.nixpkgs-upstream}" ];

  /* Old generations stay in the store until GC; frees space and pairs with boot entry limit. */
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
    persistent = true;
  };
}
