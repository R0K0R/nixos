{ ... }:

{
  # Kept separate from hardware-configuration.nix (which stays auto-generated/pristine).
  fileSystems."/nix" = {
    device = "/dev/disk/by-uuid/9a16b001-1824-437a-ba2d-7f2b44fe0398";
    fsType = "btrfs";
    options = [
      "subvol=nix"
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
