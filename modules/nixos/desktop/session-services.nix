{ ... }:

{
  /* DMS’s NixOS module turns these on with mkDefault only when HM sets
     programs.dank-material-shell on the *system* module — HM-only setups miss them.
     They are referenced by KDE Connect, GNOME-ish power UI tooling, portals, etc. */
  security.polkit.enable = true;

  services.accounts-daemon.enable = true;
  services.power-profiles-daemon.enable = true;
  services.geoclue2.enable = true;

  /*
    Cups-pk-helper is pulled in via the printing stack (dbus activation + polkit)
    once polkit-enabled printing is on.
  */
  services.printing.enable = true;

  /* systemd / logind lid policy (upstream defaults vary; laptop users expect suspend). */
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "suspend";
    HandleLidSwitchDocked = "ignore";
  };

  /*
    Bridges system suspend → user sleep.target so per-user units can react.
    Needed so we can invoke DMS lock before sleep below.
  */
  services.systemd-lock-handler.enable = true;
}
