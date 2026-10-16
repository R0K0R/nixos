/*
  User-type presets. A type is a bundle of answers to five questions (axes),
  plus the list of which answers a user of that type may change for himself.
  lib/registry.nix holds the rules -- which values exist, which combinations
  contradict, what "narrow" means -- this file is only the presets.

    home      persistent | tmpfs | impermanent
              Where the home directory lives. tmpfs = gone at logout (handover);
              impermanent = wiped at boot except for persist.nix paths.
    nix       none | overlay | untrusted | admin
              What the user may do with the nix daemon. overlay = a private
              upper store on top of the system's (guest-overlay feature);
              untrusted = the shared daemon without trusted-user rights;
              admin = trusted-users.
    session   home-manager | system-default | { kiosk = "<package attr>"; }
              What a login gets: the user's own home-manager generation, the
              system's defaults with no per-user generation, or one program.
    builders  bool -- may dispatch to the remote builders (needs nix = admin).
    grants    subset of [ sudo network media serial input ] -- capabilities a
              host turns into its own groups. Only "sudo" <-> wheel is checked
              against the host's group list today.

  `overridable` is per type and deliberately short. An override outside it is
  an error, not a silent no-op: a "member" whose file says nix = admin is an
  admin with a misleading label, and the label is what people read.

  TODO (nix trust): `nix` is validated but NOT yet wired to the daemon.
  trusted-users is still written per host (my.nix-settings.trustedUsers =
  [ "r0k0r" ] on both hosts), which happens to match today's registry exactly
  (r0k0r admin, benjamin member = untrusted). Deriving trusted-users from here
  is a system change and a workflow change (the user plans to make himself
  untrusted too, with a standalone home repo), so it is left for that step.

  TODO (builders, grants): data only. Today every user can use
  /etc/nix/machines through the daemon, and groups still come from
  registry/hosts.nix `groups` / the user file's `groups`.
*/
{
  admin = {
    home = "persistent";
    nix = "admin";
    session = "home-manager";
    builders = true;
    grants = [ "sudo" "network" "media" ];
    overridable = [ "home" "session" "grants" ];
  };

  member = {
    home = "persistent";
    nix = "untrusted";
    session = "home-manager";
    builders = false;
    grants = [ "network" "media" ];
    overridable = [ "home" "session" "grants" ];
  };

  # A guest: no store access and the system's own session unless the type's
  # overrides opt in (and nix = "overlay" additionally needs the host's
  # guest-overlay feature).
  untrusted = {
    home = "persistent";
    nix = "none";
    session = "system-default";
    builders = false;
    grants = [ ];
    overridable = [ "home" "nix" "session" ];
  };

  # A machine lent to someone: wiped at logout, one program, nothing else.
  # Which program is the only thing a handover user may choose.
  handover = {
    home = "tmpfs";
    nix = "none";
    session = { kiosk = "firefox"; };
    builders = false;
    grants = [ ];
    overridable = [ "session" ];
  };
}
