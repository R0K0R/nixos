{ lib, ... }:

{
  options.wm.compositor = lib.mkOption {
    type = lib.types.enum [ "niri" "hyprland" ];
    default = "niri";
    description = "Which Wayland compositor to enable system- and user-wide.";
  };
}
