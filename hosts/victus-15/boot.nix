{ ... }:

{
  # systemd-boot copies each generation’s kernel + initrd onto `/boot` (vfat ESP). Cap boot
  # entries so EFI doesn’t fill; excess entries are removed on `nixos-rebuild` / boot installer.
  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 10;
  };

  boot.loader.efi.canTouchEfiVariables = true;
}
