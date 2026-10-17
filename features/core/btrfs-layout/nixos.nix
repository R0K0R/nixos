/*
  /nix as its own btrfs subvolume.

  What needs it: guest-overlay snapshots /nix (store AND database, one atomic
  point in time) as the frozen lower layer of every guest's overlay store,
  and `btrfs subvolume snapshot` takes a subvolume, not a directory.

  victus-15 already has it (subvolume "nix", id 257, made when the machine
  was set up); this feature just declares that mount. galaxybook4-pro360 has
  / = the top-level subvolume with /nix a plain directory, so turning it on
  there needs the one-time migration below FIRST -- the mount would point at
  a subvolume that does not exist, and the boot would drop to the emergency
  shell.

  Migration (offline: from a live USB, or at least with nix-daemon stopped and
  nothing running from the store but the shell doing it). Not scripted on
  purpose -- it is run once per machine, by a person watching it:

    mount -o subvolid=5 /dev/disk/by-uuid/<root> /mnt
    btrfs subvolume create /mnt/@nix
    cp -a --reflink=always /mnt/nix/. /mnt/@nix/     # metadata only, no data copy
    mv /mnt/nix /mnt/nix.old && mkdir /mnt/nix       # keep the old tree until it boots
    # enable my.btrfs-layout in the host file and make that generation the
    # boot default (nixos-enter --root /mnt, then switch-to-configuration
    # boot), reboot, check that `findmnt /nix` shows subvol=/@nix, then:
    rm -rf /mnt/nix.old                              # a plain directory, not a subvolume

  Only the declaration lives here: device, subvolume name, mount options.
*/
{ config, lib, ... }:

let
  cfg = config.my.btrfs-layout;
in
{
  options.my.btrfs-layout = {
    enable = lib.mkEnableOption ''
      /nix mounted from its own btrfs subvolume (`nixSubvolume` on `device`).
      Needs the one-time migration in features/core/btrfs-layout/nixos.nix
      done first'';

    device = lib.mkOption {
      type = lib.types.str;
      default = config.fileSystems."/".device or "";
      defaultText = lib.literalExpression ''config.fileSystems."/".device'';
      description = "The btrfs filesystem holding the subvolume (by default the one / is on).";
    };

    nixSubvolume = lib.mkOption {
      type = lib.types.str;
      default = "@nix";
      description = "Subvolume mounted at /nix, relative to the top-level subvolume.";
    };

    extraOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "compress=zstd" ];
      description = "Mount options after subvol=. (NixOS already mounts /nix in the initrd.)";
    };
  };

  config = lib.mkMerge [
    { my.internal.features.btrfs-layout.enabledBy = cfg.enable; }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = (config.fileSystems."/".fsType or "") == "btrfs" && cfg.device != "";
          message = "my.btrfs-layout: / must be btrfs (and my.btrfs-layout.device set) -- the subvolume lives on the same filesystem.";
        }
      ];
      fileSystems."/nix" = {
        inherit (cfg) device;
        fsType = "btrfs";
        options = [ "subvol=${cfg.nixSubvolume}" ] ++ cfg.extraOptions;
      };
    })
  ];
}
