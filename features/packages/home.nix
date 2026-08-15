{ lib, osConfig, ... }:

lib.mkIf (osConfig.my.packages.extra.home != [ ]) {
  home.packages = osConfig.my.packages.extra.home;
}
