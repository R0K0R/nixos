/*
  my.tuning.ca -- content-addressed derivations, in TWO switchable steps.

  Step 1 (`enable`): put `ca-derivations` in the daemon's experimental
  features. Nothing else. Required first because the DAEMON enforces it: a
  CA derivation cannot be evaluated -- let alone built -- until the daemon has
  the flag, and `--extra-experimental-features` on the client does not help
  (verified 2026-09-07). Switch with only this, on every machine that
  evaluates or builds: galaxybook, victus-15, and yulee by hand (yulee.md §7).

  Step 2 (`contentAddress`): apply overlays/ca.nix to the tuned host set.
  Flipping it rebuilds the tuned closure once (CA outputs are addressed
  differently), so it wants to ride along with the mold/ccache rebuild rather
  than cost a second pass.

  DOING BOTH IN ONE SWITCH. Step 1 only takes effect when the daemon restarts,
  which is the end of a switch, so a config with both on cannot evaluate on a
  machine that has not switched yet.

  BOTH SIDES need the feature, and that is the part that misleads: the client
  evaluates `__contentAddressed` and the daemon accepts the resulting
  derivation, so enabling either one alone still fails, with an error that
  points at whichever half is missing (measured both ways). tryEval cannot
  catch it, so it cannot self-bootstrap.

  Daemon side, granted without a switch since the daemon reads NIX_CONFIG. On
  each NixOS machine, BEFORE the first switch with this on:

    sudo mkdir -p /run/systemd/system/nix-daemon.service.d
    printf '[Service]\nEnvironment="NIX_CONFIG=experimental-features = nix-command flakes ca-derivations"\n' \
      | sudo tee /run/systemd/system/nix-daemon.service.d/ca.conf
    sudo systemctl daemon-reload && sudo systemctl restart nix-daemon

  /run, so it evaporates on reboot and the switch's own nix.conf takes over.
  Do NOT restart the daemon while a build is running; it kills them. Every
  machine that BUILDS these derivations needs it too, not just the evaluator.

  Client side, for that one switch only, since /etc/nix/nix.conf does not carry
  it until the switch lands:

    sudo NIX_CONFIG="extra-experimental-features = ca-derivations" \
      nixos-rebuild switch --flake .#<host> --target-host <host> --sudo --ask-sudo-password

  `extra-` appends, so it does not clobber nix-command and flakes.

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

    stripRefChecks = lib.mkEnableOption ''
      clearing nixpkgs' reference checks on the packages that carry them, so
      they can be content-addressed too.

      Without this, CA is not usable at all here. A derivation ANYWHERE
      downstream of a content-addressed one gets a deferred output path, and a
      check naming it then holds a placeholder that nix rejects: krb5 disallows
      bashNonInteractive in its lib output and dies with "not a valid output of
      this derivation" once readline is CA (measured 2026-09-07).

      Measured 2026-09-08: 36 of 919 candidates carry any reference check --
      age audit curl direnv e2fsprogs exiv2 git iptables kbd krb5 libcap
      libpcap libpq linux-pam lvm2 man-db mesa nodejs perl python3 shadow
      systemd tailscale among them. Bounded, but it removes assertions that
      exist to catch closure creep, on packages as central as systemd and mesa.
      That is the trade; it is off by default deliberately
    '';
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
      nixpkgs.overlays = [
        (import ./overlays/ca.nix {
          inherit lib hostRuntimeClassifier;
          # Same closure overlays/heavy.nix leaves alone, for a related reason:
          # there it is a stdenv-derived-from-stdenv cycle, here it is that a
          # CA outPath is a placeholder and poisons any reference check naming
          # it. One list, one source of truth.
          skip = config.my.tuning.heavy.skip;
          inherit (cfg) stripRefChecks;
        })
      ];
    })
  ];
}
