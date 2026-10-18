{ config, lib, ... }:

let
  cfg = config.my.swapfile;
in
{
  options.my.swapfile = {
    enable = lib.mkEnableOption ''
      a btrfs swapfile at /swapfile. NixOS calls `btrfs filesystem mkswapfile`
      when `size` is set, so this only works on a btrfs root
    '';

    path = lib.mkOption {
      type = lib.types.str;
      default = "/swapfile";
      example = "/swap/swapfile";
      description = ''
        Where the swapfile lives. Under an ephemeral root (features/core/impermanence)
        it must not be on the root subvolume -- /swap/swapfile, on
        my.btrfs-layout.swap's own subvolume.
      '';
    };

    sizeMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16 * 1024;
      description = "Swapfile size in MiB.";
    };
  };

  config = lib.mkIf cfg.enable {
    swapDevices = [
      {
        device = cfg.path;
        size = cfg.sizeMiB;
      }
    ];
  };
}
