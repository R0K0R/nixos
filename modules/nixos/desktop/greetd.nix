{ config, lib, pkgs, ... }:

{
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command =
          "${lib.getExe pkgs.tuigreet} --time --remember --remember-user-session "
          + "--cmd ${config.programs.niri.package}/bin/niri-session";
        user = "greeter";
      };
    };
  };
}
