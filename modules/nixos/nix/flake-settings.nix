{ inputs, lib, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Point nix-shell / nix run / the flake registry at the unpatched upstream
  # nixpkgs so derivation hashes match what Hydra cached.  nixpkgs-upstream is
  # a separate input that --override-input nixpkgs path:... never touches.
  # nixpkgs-flake.nix also sets nix.registry.nixpkgs; mkForce wins.
  nix.registry.nixpkgs = lib.mkForce { flake = inputs.nixpkgs-upstream; };
  nix.nixPath = lib.mkForce [ "nixpkgs=${inputs.nixpkgs-upstream}" ];

  /* Automatic GC disabled while the pseudo-cross fork project is active:
     failed switch attempts leave days' worth of build artifacts unrooted by
     design, and persistent=true meant a reboot fired the missed weekly timer
     -- one boot GC'd ~3-4k locally built paths (2026-07-08). GC is a manual
     decision until the store contents stop being expensive to reproduce.
     Old settings kept for when this is re-enabled:
       dates = "weekly"; options = "--delete-older-than 14d"; persistent = true; */
  nix.gc.automatic = false;
}
