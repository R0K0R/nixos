/*
  Offload all local builds to Yulee via distributed builds.

  After this is active, plain `sudo nixos-rebuild switch` (with /etc/nixos → flake)
  builds on Yulee. Nix still uploads missing store paths over SSH (one at a time per
  builder URL) and copies results back for switch — use builders-use-substitutes.

  One-time bootstrap (before the first switch that installs this module):
    bash ~/flakes/nixos/scripts/bootstrap-yulee-builder-on-laptop.sh
    # then run switch once with --builders (see script output)

  On Yulee (/etc/nix/nix.conf):
    max-jobs = 10
    trusted-users = root @wheel r0k0r
    experimental-features = nix-command flakes
    system-features = benchmark big-parallel kvm nixos-test gccarch-meteorlake gccarch-znver3

  r0k0r must be in group nix-users on Yulee. Builder pubkey in authorized_keys
  (see modules/nixos/nix/nix-remote-builder.pub).
*/
{ config, lib, ... }:

{
  imports = [ ../network/yulee.nix ];

  nix.distributedBuilds = true;

  nix.buildMachines = [
    {
      hostName = "yulee";
      systems = [ "x86_64-linux" "i686-linux" ];
      protocol = "ssh";
      maxJobs = 10;
      speedFactor = 4;
      sshUser = "r0k0r";
      sshKey = "/etc/nix/remote-builder/ssh_key";
      # Yulee: znver3 for running bootstrap tools; meteorlake for compiling final -march=meteorlake outputs.
      supportedFeatures = lib.unique (
        # Exclude local-only features (galaxybook-*) that are only meaningful
        # on the local machine and would wrongly dispatch builds to yulee.
        lib.filter (f: !(lib.hasPrefix "galaxybook-" f)) config.nix.settings.system-features
        ++ [
          "gccarch-meteorlake"
          "gccarch-znver3"
        ]
      );
    }
  ];

  nix.settings = {
    # NixOS emits `builders =` (empty) by default, which disables Nix's built-in
    # default of @/etc/nix/machines. Point at the file buildMachines generates.
    builders = "@/etc/nix/machines";
    builders-use-substitutes = true;
    # Never build locally — delegate everything to yulee.
    max-jobs = 0;
    # Use yulee's /nix/store as a binary cache — meteorlake-specific builds
    # that miss cache.nixos.org are served from yulee directly.
    substituters = [ "ssh://r0k0r@yulee" ];
    trusted-public-keys = [ "yulee-1:KgdwkCN5m+hewJTk+A05PjwI3BbnZAE9NW2n634N7vM=" ];
  };
}
