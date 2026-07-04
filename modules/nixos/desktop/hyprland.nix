{ config, lib, ... }:

{
  config = lib.mkIf (config.wm.compositor == "hyprland") {
    programs.hyprland = {
      enable = true;
      # DMS greeter launches hyprland.desktop via uwsm regardless of this flag's
      # own default. Without withUWSM, programs.uwsm.enable never fires, so the
      # systemd user units uwsm needs (wayland-session-bindpid@.service etc.)
      # are missing -> "systemctl --user start ... exit status 5" crash loop.
      withUWSM = true;
    };
  };
}
