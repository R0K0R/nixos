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
    system-features = benchmark big-parallel kvm nixos-test gccarch-meteorlake

  r0k0r must be in group nix-users on Yulee. Builder pubkey in authorized_keys
  (see modules/nixos/nix/nix-remote-builder.pub).
*/
{ config, lib, ... }:

{
  imports = [ ../network/yulee.nix ../network/victus-15.nix ];

  nix.distributedBuilds = true;

  # Make the builder SSH key readable by r0k0r so `ssh yulee` / `ssh victus-15`
  # works interactively without a separate key. Group must be `users` --
  # there is no `r0k0r` group, and systemd-tmpfiles skips the whole line on
  # an unresolvable group ("Failed to resolve group 'r0k0r'"), silently
  # leaving the key root-owned.
  systemd.tmpfiles.rules = [
    "z /etc/nix/remote-builder/ssh_key 0600 r0k0r users -"
  ];

  nix.buildMachines = [
    {
      hostName = "yulee";
      systems = [ "x86_64-linux" "i686-linux" ];
      protocol = "ssh";
      maxJobs = 10;
      speedFactor = 10;
      sshUser = "r0k0r";
      sshKey = "/etc/nix/remote-builder/ssh_key";
      # Bootstrap tools are generic x86-64 (hit cache.nixos.org); only HOST outputs need meteorlake.
      supportedFeatures = lib.unique (
        lib.filter (f: !(lib.hasPrefix "galaxybook-" f)) config.nix.settings.system-features
        ++ [ "gccarch-meteorlake" ]
      );
    }


    {
      hostName = "victus-15";
      systems = [ "x86_64-linux" "i686-linux" ];
      protocol = "ssh";
      # 5 parallel builds drove victus deep into swap (LTO link steps are
      # memory-hungry); keep in sync with the nixos-rebuild-victus-15 /
      # nix-shell-victus-15 scripts' builder strings.
      maxJobs = 3;
      speedFactor = 4;
      sshUser = "r0k0r";
      sshKey = "/etc/nix/remote-builder/ssh_key";
      # Bootstrap tools are generic x86-64 (hit cache.nixos.org); only HOST outputs need meteorlake.
      supportedFeatures = lib.unique (
        lib.filter (f: !(lib.hasPrefix "galaxybook-" f)) config.nix.settings.system-features
        ++ [ "gccarch-meteorlake" ]
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
    substituters = [ "https://cache.nixos.org" "ssh://r0k0r@yulee" "ssh://r0k0r@victus-15" ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "yulee-1:KgdwkCN5m+hewJTk+A05PjwI3BbnZAE9NW2n634N7vM="
      "victus-15-1:W5OP8VVbu7Q7z2o5grHJ5Zp+ynm536+QVv+b8fBQJlQ="
    ];
  };
}
