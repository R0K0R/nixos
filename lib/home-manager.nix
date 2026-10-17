/*
  home-manager wiring, in one place because TWO callers need it and they used to
  disagree.

  mkHost sets this up for real hosts. tuning/runtime-cache/tier2-eval.nix builds
  its own throwaway "pass1" config to compute Tier 2 anchors, and that config
  must see the same home-manager users -- home.packages is one of its anchor
  sources.

  It broke exactly once: the wiring used to live in a module the host file
  imported, so pass1 got it for free. Moving it into mkHost left pass1 with no
  home-manager users at all, so imagemagick, eza and every other home package
  silently stopped being anchors and got classified as not-host-runtime, i.e.
  built untuned. Nothing failed; the packages were still installed. Only the
  tuning quietly went away.
*/
{ homeModules, inputs, hostName }:

let
  # Shared with homeLib's standalone mkHome; see lib/home-generator.nix.
  gen = import ./home-generator.nix { inherit homeModules inputs hostName; };
in
{ config, lib, pkgs, ... }:

let
  standalone = gen.standaloneUsers lib config;
in
{
  /*
    A standalone account (homeActivation = "standalone") activates its home
    itself: `home-manager switch --flake ~/config/home`. The CLI is the
    system's, built from the same home-manager input the generator and
    homeLib use -- a CLI from another release would run a different
    activation than the one the home was evaluated against. Only on a host
    that has such an account, so other hosts' toplevels do not move.
  */
  environment.systemPackages = lib.mkIf (standalone != { }) [
    (pkgs.callPackage "${inputs.home-manager}/home-manager" {
      path = "${inputs.home-manager}";
      # Its `home-manager option` wraps nixos-option, which puts pkgs.nix on
      # PATH -- 2.34, a second Nix next to the system's nix.package (2.35)
      # and the client/daemon split that broke CA builds before. Same
      # nixos-option, the system's Nix.
      pkgs = pkgs // { nixos-option = pkgs.nixos-option.override { nix = config.nix.package; }; };
    })
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    inherit (gen) extraSpecialArgs;
    backupFileExtension = "hm-backup";
    # Allow replacing an existing *.hm-backup when backing up again (avoids an
    # activation crash on the second run).
    overwriteBackup = true;

    /*
      Feature home halves, plus Unstraightened's own module. In sharedModules
      rather than a per-user config so one `my.<feature>.enable = true` in the
      host file drives both halves; the home side gates on osConfig.my.*.
    */
    inherit (gen) sharedModules;

    /*
      Generated from my.users, never hardcoded.

      It used to say `users.r0k0r = { }`, which built an r0k0r home-manager
      configuration on EVERY host -- including one whose only human was someone
      else. That is how the two halves of the same bug met: home-manager sets
      `home.username` from this attribute name, a feature's home half in
      sharedModules set it again to a different person, and the definitions
      collided. The host did not evaluate at all.

      THE RULE: anything per-user is generated HERE, into
      home-manager.users.<name> -- by gen.userModule, which homeLib's
      standalone mkHome applies too, so the two homes cannot drift.
      sharedModules are evaluated once per user and may only carry what is
      true of every user, so an identity -- username,
      home directory, stateVersion -- can never live in one. Features scope
      themselves per user through lib/in-scope.nix instead, which is a `config`
      condition rather than an identity.

      `imports` deliberately stays empty: every home module is a feature half
      arriving via sharedModules above. Filtering THOSE per user is impossible
      -- imports resolve before the fixpoint, so they cannot read config -- and
      that impossibility is exactly why the scoping lives inside each module.
    */
    # homeActivation = "system" accounts only; see gen.systemUsers.
    users = gen.users lib config;
  };
}
