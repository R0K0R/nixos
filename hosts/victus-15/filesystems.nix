{ ... }:

{
  # Kept separate from hardware-configuration.nix (which stays auto-generated/pristine).
  # /nix is its own subvolume ("nix"), which guest-overlay's snapshots need;
  # the mount is declared by features/core/btrfs-layout.
  my.btrfs-layout = {
    enable = true;
    device = "/dev/disk/by-uuid/9a16b001-1824-437a-ba2d-7f2b44fe0398";
    nixSubvolume = "nix";
    extraOptions = [
      "compress=zstd"
      "device=/dev/disk/by-uuid/9a16b001-1824-437a-ba2d-7f2b44fe0398"
    ];
  };

  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 49152;
    }
  ];
}
