{ config, lib, ... }:

{
  /*
    Flamenco (Blender render farm):

      service.nix  the manager service and its pinned 3.9.2 binary
      sshfs.nix    group membership + authorized key so the SSHFS client can
                   write into the manager's shared directory
      home.nix     the Blender addon, installed into the user's Blender config

    `imports` cannot be gated, so each file gates its own config on
    my.flamenco.enable.
  */
  imports = [
    ./service.nix
    ./sshfs.nix
  ];

  options.my.flamenco.enable =
    lib.mkEnableOption "Flamenco render-farm manager, its SSHFS share access, and the Blender addon";

  # Accounts this feature applies to; defaults to the primary user.
  options.my.flamenco.users = import ../../lib/user-scope.nix { inherit lib config; };
}
