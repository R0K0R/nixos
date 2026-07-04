{ pkgs, ... }:

{
  boot.kernelPackages = pkgs.linuxPackages_7_1;

  boot.loader.systemd-boot = {
    enable = true;
    # ESP is ~1GB with only ~60MB/generation (kernel+initrd) — plenty of
    # headroom for a much deeper rollback window than the old 2-generation limit.
    configurationLimit = 15;
  };

  boot.loader.systemd-boot.extraEntries = {
    "windows.conf" = ''
      title Windows
      efi /EFI/Microsoft/Boot/bootmgfw.efi
      sort-key o_windows
    '';
    "netboot.conf" = ''
      title Netboot
      efi /EFI/netboot/netboot.xyz.efi
      sort-key o_netboot
    '';
    "asclepius.conf" = ''
      title Asclepius
      efi /EFI/Asclepius/bootx64.efi
      sort-key o_asclepius
    '';
  };

  boot.loader.efi.canTouchEfiVariables = true;
}
