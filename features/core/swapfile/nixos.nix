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

    sizeMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16 * 1024;
      description = "Swapfile size in MiB.";
    };
  };

  config = lib.mkIf cfg.enable {
    swapDevices = [
      {
        device = "/swapfile";
        size = cfg.sizeMiB;
      }
    ];
  };
}
