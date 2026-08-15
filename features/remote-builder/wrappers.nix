{ config, lib, pkgs, ... }:

let
  cfg = config.my.remote-builder.client;

  flakeRef = "${cfg.flakePath}#${config.networking.hostName}";

  /*
    Generated per peer instead of written out by hand. The hand-written versions
    hardcoded `--flake /home/r0k0r/flakes/nixos#galaxybook4-pro360` in three
    places and the peer's own name in six, which meant a cloned host silently
    rebuilt the machine it was copied from -- the worst kind of failure, because
    it succeeds and does the wrong thing.

    Arguments are assembled as a LIST and joined, never interpolated as optional
    `\`-continued lines. An omitted optional line left a dangling backslash
    followed by a blank line, which terminates the command early -- the script
    still ran, but silently dropped "$@", so `nixos-rebuild-victus-15 switch`
    rebuilt nothing and reported success.
  */
  mkScript =
    name: args:
    pkgs.writeScriptBin name ''
      #! /bin/sh
      exec ${lib.concatStringsSep " \\\n  " args} "$@"
    '';

  builderSpec =
    name: p:
    "ssh://${p.sshUser}@${name} x86_64-linux ${cfg.sshKey} "
    + "${toString p.maxJobs} ${toString p.speedFactor} ${lib.concatStringsSep "," p.features}";

  substituterArgs =
    name: p:
    lib.optional p.useAsSubstituter
      ''--option substituters "https://cache.nixos.org ssh://${p.sshUser}@${name}"'';

  /*
    `--option builders`, NOT the bare `--builders` flag, and the difference is
    not cosmetic.

    nixos-rebuild-ng sorts its arguments into groups. `--builders` sits in
    common_build_flags, which reaches the BUILD step only. `--option` sits in
    common_flags, which reaches evaluation as well.

    That matters here because nix-doom-emacs-unstraightened uses
    import-from-derivation: doom-intermediates has to be BUILT during
    evaluation. With bare `--builders`, that build is dispatched before the flag
    applies, so it falls back to nix.conf's `builders = @/etc/nix/machines` --
    the full peer list, in speedFactor order. `nixos-rebuild-victus-15` would
    then try yulee first and hang on it, which is the exact opposite of what the
    name promises.

    The hand-written wrappers this replaces had it both ways: nix-shell-<peer>
    used `--option builders` and was right, nixos-rebuild-<peer> used
    `--builders` and was not.
  */
  rebuildFor = name: p: mkScript "nixos-rebuild-${name}" (
    [ "nixos-rebuild" "--flake ${flakeRef}" "--option max-jobs 0" ''--option builders "${builderSpec name p}"'' ]
    ++ substituterArgs name p
  );

  shellFor = name: p: mkScript "nix-shell-${name}" (
    [ "nix-shell" "--option max-jobs 0" ''--option builders "${builderSpec name p}"'' ]
    ++ substituterArgs name p
  );

  localArgs = [
    "--option max-jobs ${toString cfg.localJobs}"
    "--option cores ${toString cfg.localCores}"
    ''--option substituters "https://cache.nixos.org"''
  ];

  localRebuild = mkScript "nixos-rebuild-local" (
    # Same --option reasoning as rebuildFor: an empty builder list has to apply
    # during evaluation too, or an IFD build escapes to /etc/nix/machines.
    [ "nixos-rebuild" "--flake ${flakeRef}" ''--option builders ""'' ] ++ localArgs
  );

  localShell = mkScript "nix-shell-local" (
    [ "nix-shell" ''--option builders ""'' ] ++ localArgs
  );
in
lib.mkIf (cfg.enable && cfg.wrappers.enable) {
  environment.systemPackages =
    [ localRebuild localShell ]
    ++ lib.mapAttrsToList rebuildFor cfg.peers
    ++ lib.mapAttrsToList shellFor cfg.peers;
}
