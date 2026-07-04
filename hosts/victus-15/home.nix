{ ... }:

{
  /*
    Minimal home-manager profile — just enough for the shared claude-code npm
    activation hook (modules/home/r0k0r/cli/claude-code.nix). Deliberately NOT
    importing the full modules/home/r0k0r tree (niri/hyprland/DMS/emacs/etc.) —
    this host has no desktop session at all.
  */
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    overwriteBackup = true;
    users.r0k0r = {
      imports = [ ../../modules/home/r0k0r/cli/claude-code.nix ];
      home.stateVersion = "26.05";
    };
  };
}
