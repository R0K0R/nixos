{ config, lib, pkgs, ... }:

let
  cfg = config.my.network;
in
{
  options.my.network = {
    enable = lib.mkEnableOption "NetworkManager (configure interactively with nmcli or nmtui)";

    kdeconnect.enable = lib.mkEnableOption ''
      KDE Connect, via the upstream programs.kdeconnect module: the package and
      the TCP+UDP 1714-1764 ranges it actually needs

      THIS USED TO OPEN UDP 1716 AND NOTHING ELSE, on the reasoning that the
      package was a separate concern from the firewall rule. That was the wrong
      port list, and the symptom was subtle enough to be worth recording.

      UDP 1716 carries only the discovery BROADCAST. The connection itself is
      TCP, on a port in 1714-1764, opened by whichever side RECEIVES a broadcast
      back to the sender. So with only 1716 open:

        phone broadcasts -> laptop hears it -> laptop dials out  -> works
        laptop broadcasts -> phone hears it -> phone dials in    -> dropped

      Which half you land in is a race at session start, so the pairing appears
      to work sometimes, and restarting the daemon "fixes" it by forcing a fresh
      broadcast that lands the other way round. Observed as a phone that stayed
      paired but unreachable while a local Waydroid device -- which never has to
      cross the firewall -- connected fine.
    '';
  };

  # Accounts the KDE Connect daemon runs for; defaults to the primary user.
  options.my.network.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable {
    networking.networkmanager.enable = true;

    # OpenVPN through NetworkManager (and thus nm-applet): the plugin adds the
    # OpenVPN connection type, so the applet's VPN menu can import a .ovpn and
    # connect, and nm-connection-editor gains OpenVPN pages. Independent of
    # features/openvpn's standalone `openvpn-home` systemd service -- this is
    # the click-from-the-tray route, that one is the always-on config-file
    # route; keep whichever fits a given profile.
    networking.networkmanager.plugins = [ pkgs.networkmanager-openvpn ];

    /*
      Delegated rather than reimplemented. The upstream module is four lines of
      config, but it is the four lines that were got wrong by hand, and it keeps
      the port range correct if the protocol ever changes. It also installs the
      package, so features/desktop-apps no longer carries kdeconnect-kde.
    */
    programs.kdeconnect.enable = cfg.kdeconnect.enable;

    /*
      playerctl travels with KDE Connect, not just with features/media.

      The MPRIS plugin is the reason: KDE Connect both consumes local players
      and PUBLISHES remote ones onto this session bus, as
      org.mpris.MediaPlayer2.kdeconnect.mpris_* -- the phone's player and, with
      Waydroid paired to itself, Waydroid's. Those are ordinary MPRIS names, so
      playerctl drives them exactly like a local mpv, from a script or a TTY,
      with no compositor binding and no shell running.

      Deliberately also listed in features/media/packages.nix. A feature is
      meant to be self-contained -- someone enabling kdeconnect and nothing
      else should still get a working MPRIS CLI -- and duplicate entries cost
      nothing, since buildEnv dedups identical derivations.

      Gated on kdeconnect specifically rather than on my.network.enable: a
      headless host wants NetworkManager without an MPRIS client.
    */
    environment.systemPackages = lib.mkIf cfg.kdeconnect.enable [ pkgs.playerctl ];
  };
}
