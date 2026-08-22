{ lib, osConfig, ... }:

lib.mkIf osConfig.my.user-benjamin.enable {
  home.username = "benjamin";
  home.homeDirectory = "/home/benjamin";

  # Home Manager compatibility version (see HM `modules/misc/version.nix`).
  home.stateVersion = osConfig.my.user-benjamin.stateVersion;
}
