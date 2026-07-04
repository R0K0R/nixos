{ ... }:

{
  networking.networkmanager.enable = true;
  networking.firewall.enable = false;

  services.openssh.enable = true;

  services.tailscale = {
    enable = true;
    authKeyFile = "/var/lib/tailscale/authkey";
  };

  # Clamshell mode — this host runs closed-lid as a remote builder.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };
}
