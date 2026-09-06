{ config, lib, pkgs, osConfig, ... }:

let
  # sharedModules are evaluated once per user; this is what makes the
  # daemon start only for the accounts my.network.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "network"; };
in
lib.mkIf (osConfig.my.network.enable && inScope) (lib.mkMerge [

  {
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
  }

  (lib.mkIf osConfig.my.network.kdeconnect.enable {
  /*
    Start kdeconnectd with the session instead of leaving it to D-Bus activation.

    Nothing in this config starts it: programs.kdeconnect installs the package
    and opens the ports, and the package ships an XDG autostart entry that this
    session never runs -- `app-org.kde.kdeconnect.daemon@autostart.service` was
    present but had no ActiveEnterTimestamp, i.e. generated and never started.
    The daemon only appeared because something later touched org.kde.kdeconnect
    on the bus and D-Bus activated it.

    That is what broke the DMS plugin. D-Bus activation returns as soon as the
    service claims its name, but the daemon's device list populates afterwards,
    so a client that queries immediately gets an empty answer and does not
    retry. Hence the symptom: restarting DMS did not help, but opening the KDE
    Connect app first did -- the app forced the daemon up and gave it time to
    populate before DMS asked.

    Ordered Before graphical-session.target so it is up before the shell that
    queries it, rather than merely alongside.
  */
  systemd.user.services.kdeconnectd = {
    Unit = {
      Description = "KDE Connect daemon";
      PartOf = [ "graphical-session.target" ];
      Before = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.kdePackages.kdeconnect-kde}/bin/kdeconnectd";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
  })
])
