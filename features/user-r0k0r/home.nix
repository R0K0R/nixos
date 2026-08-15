{ lib, osConfig, ... }:

lib.mkIf osConfig.my.user-r0k0r.enable {
  home.username = "r0k0r";
  home.homeDirectory = "/home/r0k0r";

  # Home Manager compatibility version (see HM `modules/misc/version.nix`).
  home.stateVersion = osConfig.my.user-r0k0r.stateVersion;
}
