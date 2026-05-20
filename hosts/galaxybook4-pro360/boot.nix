{ ... }:

{
  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 2;
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
