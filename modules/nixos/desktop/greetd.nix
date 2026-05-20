{ config, lib, pkgs, ... }:

let
  dmsGreeter = lib.attrByPath [ "programs" "dank-material-shell" "greeter" "enable" ] false config;
in
{
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        user = "greeter";
      } // lib.optionalAttrs (!dmsGreeter) {
        command =
          "${lib.getExe pkgs.tuigreet} --time --remember --remember-user-session "
          + "--cmd ${config.programs.niri.package}/bin/niri-session";
      };
    };
  };
}
