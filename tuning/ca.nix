/*
  my.tuning.ca -- content-addressed derivations, in TWO switchable steps.

  Step 1 (`enable`): put `ca-derivations` in the daemon's experimental
  features. Nothing else. Required first because the DAEMON enforces it: a
  CA derivation cannot be evaluated -- let alone built -- until the daemon has
  the flag, and `--extra-experimental-features` on the client does not help
  (verified 2026-09-07). Switch with only this, on every machine that
  evaluates or builds: galaxybook, victus-15, and yulee by hand (yulee.md §7).

  Step 2 (`contentAddress`): apply overlays/ca.nix to the tuned host set. Its
  own switch, off by default, so step 1 can land and be confirmed on all three
  before any derivation changes shape. Flipping it rebuilds the tuned closure
  once (CA outputs are addressed differently); that coincides with the heavy
  list's one-time rebuild, so do both in the same switch.

  Known open risk, deliberately not hidden: realisation propagation between
  yulee (Nix 2.18.1) and the 2.34.8 hosts over the remote-build protocol. The
  builders are declared as ssh:// (legacy serve protocol); if CA builds refuse
  to dispatch, the first thing to try is ssh-ng:// in features/remote-builder.
*/
{ config, inputs, lib, hostName, ... }:

let
  cfg = config.my.tuning.ca;
  hostRuntimeClassifier = import ./host-runtime-classifier.nix {
    inherit inputs;
    host = hostName;
    system = "x86_64-linux";
  };
in
{
  options.my.tuning.ca = {
    enable = lib.mkEnableOption "step 1: the ca-derivations experimental feature on this host's daemon";
    contentAddress = lib.mkEnableOption "step 2: mark the tuned host set __contentAddressed (only after step 1 is live on galaxybook, victus-15 AND yulee)";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      nix.settings.experimental-features = [ "ca-derivations" ];
    })
    (lib.mkIf cfg.contentAddress {
      assertions = [
        {
          assertion = cfg.enable && config.my.tuning.enable && config.my.tuning.march != null;
          message = "my.tuning.ca.contentAddress needs my.tuning.ca.enable (step 1 live everywhere first) and a march'd host.";
        }
      ];
      nixpkgs.overlays = [ (import ./overlays/ca.nix { inherit lib hostRuntimeClassifier; }) ];
    })
  ];
}
