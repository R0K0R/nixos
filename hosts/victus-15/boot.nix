{ ... }:

{
  # systemd-boot copies each generation’s kernel + initrd onto `/boot` (vfat ESP). Cap boot
  # entries so EFI doesn’t fill; excess entries are removed on `nixos-rebuild` / boot installer.
  boot.loader.systemd-boot = {
    enable = true;
    # ESP is 96 MiB; each generation can add ~40 MiB (kernel + initrd). Keep few entries.
    configurationLimit = 2;
  };

  boot.loader.efi.canTouchEfiVariables = true;
}
