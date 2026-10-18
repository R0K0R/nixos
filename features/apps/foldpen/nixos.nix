{ config, inputs, lib, ... }:

let
  cfg = config.my.foldpen;
in
{
  /*
    A phone (Galaxy Z Fold 6) as a stylus for Hyprland: S Pen and finger in,
    optional low-fps screen mirror out, everything driven by 3-finger gestures
    on the phone. See ~/git_shit/foldpen/README.md.

    Imported unconditionally (the module only declares services.foldpen until
    enabled), for the same reason features/niri imports its module here.
  */
  imports = [ inputs.feat-foldpen.nixosModule ];

  options.my.foldpen = {
    enable = lib.mkEnableOption "foldpen, the phone-as-stylus daemon (Hyprland only)";
    users = import ../../../lib/user-scope.nix { inherit lib config; };
  };

  config = lib.mkIf (cfg.enable && config.my.desktop.compositor == "hyprland") {
    services.foldpen = {
      enable = true;
      inherit (cfg) users;
    };
  };
}
