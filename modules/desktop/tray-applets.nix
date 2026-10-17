{ config, lib, pkgs, ... }:

let
  cfg = config.my.trayApplets;
in
{
  options.my.trayApplets.enable = lib.mkEnableOption ''
    the NetworkManager and Bluetooth tray applets (nm-applet, blueman-applet) as user services.
    The daemons behind them (NetworkManager, services.blueman) are system services -- the system
    must have them enabled. KDE Connect's own user service is the system flake's (its network
    feature), not repeated here
  '';

  config = lib.mkIf cfg.enable {
    /*
      nm-applet: the NetworkManager tray applet -- the blueman-applet of the
      network world. A network icon in the bar's tray whose menu lists Wi-Fi
      networks to click-and-connect, toggles radios, and shows the active
      connection -- the everyday GUI, as opposed to nm-connection-editor,
      which only edits saved connection PROFILES.

      --indicator so it speaks the StatusNotifier (appindicator) protocol
      waybar's tray understands; the default XEmbed tray is invisible on
      wlroots. After graphical-session.target so the tray host is up first.
    */
    systemd.user.services.nm-applet = {
      Unit = {
        Description = "NetworkManager tray applet";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.networkmanagerapplet}/bin/nm-applet --indicator";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # blueman-applet: the Bluetooth tray applet, beside nm-applet. Its backend
    # (services.blueman) is enabled by features/discovery. StatusNotifier by
    # default, so it shows in waybar's tray with no extra flag.
    systemd.user.services.blueman-applet = {
      Unit = {
        Description = "Blueman Bluetooth tray applet";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.blueman}/bin/blueman-applet";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
