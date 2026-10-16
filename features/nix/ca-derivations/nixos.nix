/*
  my.ca-derivations -- content-addressed derivations, as a feature of its own.

  It used to be my.tuning.ca, which made CA look like a consequence of tuning.
  It is not: the daemon flag is a property of the Nix installation, and which
  packages become floating-CA is a policy that merely happens to have one
  sensible answer today (the tuned host set, see below). So the switch and the
  policy live here, and tuning/ca.nix only APPLIES the policy, because the
  overlay that does it needs tuning's classifier and heavy.skip list.

  TWO STEPS, separately switchable, exactly as before the move:

  Step 1 (`enable`): put `ca-derivations` in the daemon's experimental
  features. Nothing else. Required first because the DAEMON enforces it: a
  CA derivation cannot be evaluated -- let alone built -- until the daemon has
  the flag, and `--extra-experimental-features` on the client does not help
  (verified 2026-09-07). Switch with only this, on every machine that
  evaluates or builds: galaxybook, victus-15, and yulee by hand (yulee.md §7).

  Step 2 (`packages = "tuned"`): tuning/overlays/ca.nix marks the tuned host
  set __contentAddressed. Flipping it rebuilds the tuned closure once (CA
  outputs are addressed differently), so it wants to ride along with another
  rebuild rather than cost a second pass. "tuned" asserts my.tuning.march: the
  overlay keys off the IntraISACross suffix and gcc.arch, so without march the
  set is empty and the policy would be silently inert. That is why the policy
  is an enum and not a bool -- "every host-runtime package" on an untuned host
  is a different trade (it gives up cache.nixos.org substitution, which the
  tuned set never had), and deserves its own value if it is ever wanted.

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

  NOT read by flake.nix. Unlike march, nothing about CA decides which nixpkgs
  input a host gets -- it is an overlay plus a nix.conf line, both ordinary
  module config -- so it needs no raw-import literal and no agreement
  assertion. It may be set from anywhere, mkIf included.
*/
{ config, lib, ... }:

let
  cfg = config.my.ca-derivations;
in
{
  options.my.ca-derivations = {
    enable = lib.mkEnableOption "step 1: the ca-derivations experimental feature on this host's nix (daemon and client)";

    packages = lib.mkOption {
      type = lib.types.enum [ "none" "tuned" ];
      default = "none";
      description = ''
        Which packages become floating content-addressed (step 2).

        "none": only the experimental feature; every derivation stays
        input-addressed. Useful on a builder that must ACCEPT CA derivations
        from its clients without producing any itself.

        "tuned": the tuned host set (tuning/overlays/ca.nix), i.e. the
        host-runtime packages that already differ from upstream because of
        my.tuning.march and so never substituted from cache.nixos.org --
        CA costs them nothing there and buys early cutoff. Requires
        my.ca-derivations.enable (step 1 live on galaxybook, victus-15 AND
        yulee first) and my.tuning.march.
      '';
    };

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
    # Declared unconditionally so features/_meta can see the feature while it
    # is off (same shape as features/agenix).
    { my.internal.features.ca-derivations.enabledBy = cfg.enable; }

    (lib.mkIf cfg.enable {
      /*
        mkAfter: list definitions concatenate in module import order, and this
        feature sorts before nix-settings, which defines nix-command/flakes.
        The line used to come from tuning/, imported after every feature, so
        nix.conf read "nix-command flakes ca-derivations"; keeping that order
        keeps /etc/nix/nix.conf (and the etc derivation) byte-identical.
      */
      nix.settings.experimental-features = lib.mkAfter [ "ca-derivations" ];
    })

    {
      assertions = [
        {
          assertion = cfg.packages == "none" || cfg.enable;
          message =
            "my.ca-derivations.packages = \"${cfg.packages}\" needs my.ca-derivations.enable = true "
            + "(and step 1 live on every evaluator and builder first; see features/nix/ca-derivations).";
        }
        {
          assertion = !cfg.stripRefChecks || cfg.packages != "none";
          message = "my.ca-derivations.stripRefChecks does nothing with packages = \"none\"; set packages or drop it.";
        }
      ];
    }
  ];
}
