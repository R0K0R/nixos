{ config, inputs, pkgs, ... }:

let
  primaryLogin = "r0k0r";
in
{
  # The greeter moved out of dms itself into its own repo/module.
  imports = [ inputs.dank-greeter.nixosModules.default ];

  programs.dms-greeter = {
    enable = true;
    compositor.name = config.wm.compositor;

    configHome = config.users.users.${primaryLogin}.home;

    logs = {
      save = true;
      path = "/tmp/dms-greeter.log";
    };

    quickshell.package = pkgs.quickshell;
  };
}
