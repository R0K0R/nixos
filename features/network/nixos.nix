{ config, lib, ... }:

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

  config = lib.mkIf cfg.enable {
    networking.networkmanager.enable = true;

    /*
      Delegated rather than reimplemented. The upstream module is four lines of
      config, but it is the four lines that were got wrong by hand, and it keeps
      the port range correct if the protocol ever changes. It also installs the
      package, so features/desktop-apps no longer carries kdeconnect-kde.
    */
    programs.kdeconnect.enable = cfg.kdeconnect.enable;
  };
}
