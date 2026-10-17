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
    builders  bool -- may name builders and substituters of his own (needs
              nix = admin: --builders is a trusted-user setting). It cannot
              keep a user's builds off the host daemon's OWN builders; the
              daemon dispatches for everyone it accepts. lib/registry.nix's
              header and `nixFacts` say what actually happens.
    grants    subset of [ sudo network media serial input ] -- capabilities a
              host turns into its own groups. Only "sudo" <-> wheel is checked
              against the host's group list today.

  `rank` orders the types for transitions: moving a deployed user to a type
  of lower rank is a demotion, refused at switch time (when
  my.registry.recordTypes is on) unless his file says
  acceptTypeChange = "<old>-><new>". See lib/registry.nix `transition`.

  Per-user keys that go with some types (registry/users/<name>.nix):
    tmpfsSize         size= of a tmpfs home, default "2G".
    acceptTypeChange  "<old type>-><new type>": consent to one dangerous
                      transition. Inert once the new type is recorded.

  `overridable` is per type and deliberately short. An override outside it is
  an error, not a silent no-op: a "member" whose file says nix = admin is an
  admin with a misleading label, and the label is what people read.

  NIX TRUST. nix = "none" drives allowed-users; trusted-users is exactly the
  host's nix = "admin" accounts (plus root and
  my.registry.nix.extraTrustedUsers), and every other registry user is
  asserted absent from it. Making someone untrusted is changing his type
  here, not editing a host file.

  TODO (grants): data only beyond sudo <-> wheel; groups still come from
  registry/hosts.nix `groups` / the user file's `groups`.
*/
{
  admin = {
    home = "persistent";
    nix = "admin";
    session = "home-manager";
    builders = true;
    grants = [ "sudo" "network" "media" ];
    rank = 3;
    overridable = [ "home" "session" "grants" ];
  };

  member = {
    home = "persistent";
    nix = "untrusted";
    session = "home-manager";
    builders = false;
    grants = [ "network" "media" ];
    rank = 2;
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
    rank = 1;
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
    rank = 0;
    overridable = [ "session" ];
  };
}
