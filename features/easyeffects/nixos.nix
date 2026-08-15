{ lib, ... }:

{
  options.my.easyeffects.enable = lib.mkEnableOption ''
    the EasyEffects preset collection, installed into the user's config.
    EasyEffects itself is a package, installed separately
  '';
}
