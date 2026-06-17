{ ... }:

{
  # Root is btrfs on both hosts; NixOS uses `btrfs filesystem mkswapfile` when size is set.
  swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024; # 16 GiB
    }
  ];
}
