/*
  Applies my.ca-derivations.packages = "tuned": overlays/ca.nix over the tuned
  host set.

  The switch, the policy, the daemon flag and the bootstrap procedure all live
  in features/nix/ca-derivations now; CA is not implied by tuning and a host
  with tuning on gets none of it unless it says so. This file stays in tuning/
  only because the overlay is built from tuning's own machinery -- the shared
  host-runtime classifier and heavy.skip -- which a feature cannot reach
  without dragging tuning in with it.

  Gated on the FEATURE's switches, never on my.tuning.enable alone: tuning on
  means "this host runs a tuned package set", not "this host has
  ca-derivations in its daemon", and conflating the two is exactly what made
  CA look like part of tuning.
*/
{ config, lib, hostRuntimeClassifier, ... }:

let
  ca = config.my.ca-derivations;
  # hostRuntimeClassifier: the shared instance from tuning/nixos.nix (_module.args).
in
{
  config = lib.mkIf (ca.packages == "tuned") {
    assertions = [
      {
        assertion = config.my.tuning.enable && config.my.tuning.march != null;
        message =
          "my.ca-derivations.packages = \"tuned\" needs a march'd host (my.tuning.enable and my.tuning.march): "
          + "the tuned host set is empty without gcc.arch, so the policy would be silently inert.";
      }
    ];
    nixpkgs.overlays = lib.mkIf ca.enable [
      (import ./overlays/ca.nix {
        inherit lib hostRuntimeClassifier;
        # Same closure overlays/heavy.nix leaves alone, for a related reason:
        # there it is a stdenv-derived-from-stdenv cycle, here it is that a
        # CA outPath is a placeholder and poisons any reference check naming
        # it. One list, one source of truth.
        skip = config.my.tuning.heavy.skip;
        inherit (ca) stripRefChecks;
      })
    ];
  };
}
