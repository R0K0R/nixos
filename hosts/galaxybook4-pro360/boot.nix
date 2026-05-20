{ pkgs, ... }:

{
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
    useOSProber = false;
    configurationLimit = 10;
    /* starfield lives on ESP already; nixpkgs no longer ships nixos-grub-themes.starfield. */
    theme = pkgs.nixos-grub2-theme;
    extraEntries = ''
      menuentry "Windows" {
        insmod part_gpt
        insmod fat
        search --no-floppy --fs-uuid --set=root 26A5-2CDE
        chainloader /EFI/Microsoft/Boot/bootmgfw.efi
      }
      menuentry "Netboot" {
        insmod part_gpt
        insmod fat
        search --no-floppy --fs-uuid --set=root 26A5-2CDE
        chainloader /EFI/netboot/netboot.xyz.efi
      }
      menuentry "Asclepius" {
        insmod part_gpt
        insmod fat
        search --no-floppy --fs-uuid --set=root 26A5-2CDE
        chainloader /EFI/Asclepius/bootx64.efi
      }
    '';
  };

  /* Incompatible with boot.loader.grub.efiInstallAsRemovable on multi-boot ESPs. */
  boot.loader.efi.canTouchEfiVariables = false;
}
