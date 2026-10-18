/*
  galaxybook4-pro360 AFTER the impermanence migration (docs/impermanence-migration.md).
  NOT imported by default.nix yet: until the live-USB session, the disk is flat
  (/, /home, /nix are folders in subvolid 5) and this layout would not boot.

  Before the session: `migration.galaxybook4-pro360` (flake.nix) is this host
  with this file and the registry changes below applied -- build it on victus,
  so the USB session installs a finished system instead of compiling one.

  On the day, the switch to it is three edits that must reproduce exactly that
  toplevel (check the drvPath):
    - hosts/galaxybook4-pro360/default.nix imports ./impermanence.nix
    - registry/hosts.nix: features.galaxybook4-pro360.impermanence = true
    - registry/users/r0k0r.nix: overrides.home = "impermanent";
      acceptTypeChange = "admin->admin";
*/
{ config, ... }:

let
  primaryHome = config.users.users.${config.my.internal.primaryUser}.home;
in
{
  my.btrfs-layout = {
    enable = true;
    nixSubvolume = "@nix";
    rootSubvolume = "@root";
    persist.enable = true;
    swap.enable = true;
    # 27G, kept whole as its own subvolume (HANDOFF §3): never snapshotted with
    # the root, never part of a persist list.
    extraMounts."${primaryHome}/Backups/windows".subvolume = "@windows-backup";
  };

  my.swapfile.path = "/swap/swapfile";

  my.impermanence.enable = true;

  # /etc/nixos was a symlink to the flake made by hand; a fresh root would lose
  # it. Declared from the option the rebuild tooling already reads, so the
  # path stays defined in one place.
  systemd.tmpfiles.rules = [ "L+ /etc/nixos - - - - ${config.my.tuning.flakePath}" ];
}
