{ config, inputs, pkgs, ... }:

let
  primaryLogin = "r0k0r";
in
{
  imports = [ inputs.dms.nixosModules.greeter ];

  programs.dank-material-shell.greeter = {
    enable = true;
    compositor.name = "niri";

    configHome = config.users.users.${primaryLogin}.home;

    logs = {
      save = true;
      path = "/tmp/dms-greeter.log";
    };

    quickshell.package = pkgs.quickshell;
  };
}
