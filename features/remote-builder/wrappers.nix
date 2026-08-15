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
    `--option builders` rather than the bare `--builders` flag: it reaches both
    the build step and (for nix-shell) the evaluation, and it matches what the
    nix-shell wrappers always used.

    IT DOES NOT MAKE THE NAME TRUE, and an earlier version of this comment
    wrongly claimed it did. nixos-rebuild-ng composes flake_eval_flags from its
    own argument group ONLY -- models.py:183, `vars(args_groups["flake_eval_flags"])`,
    with no `common_flags |` -- so no flag of any kind reaches the `nix eval`
    invocation in build_flake. That invocation is where import-from-derivation
    builds happen, and with nix-doom-emacs-unstraightened that means
    doom-intermediates. Such a build is dispatched by the daemon via nix.conf's
    `builders = @/etc/nix/machines`: the whole peer list, in speedFactor order,
    regardless of what this script says.

    So `nixos-rebuild-victus-15` restricts the BUILD phase to victus-15 and
    cannot restrict the EVAL phase at all. To genuinely exclude a peer, park it
    with `my.remote-builder.client.peers.<name>.enable = false`, which removes it
    from /etc/nix/machines.
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
