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
              | { desktop = "gnome"; }
              What a login gets: the user's own home-manager generation, the
              system's defaults with no per-user generation, one program, or
              one desktop. kiosk and desktop are PINNED: whatever the greeter
              offers or remembers, a greetd login of the account runs that
              session (features/core/users/session-pin.nix). A kiosk is the
              program under cage and the account's login shell; a desktop
              (lib/registry.nix axisValues.desktop: "gnome") is the system's
              GNOME, from the host's features/session/gnome, and the account
              keeps a real shell (its terminal has one anyway).
    builders  bool -- may name builders and substituters of his own (needs
              nix = admin: --builders is a trusted-user setting). It cannot
              keep a user's builds off the host daemon's OWN builders; the
              daemon dispatches for everyone it accepts. lib/registry.nix's
              header and `nixFacts` say what actually happens.
    grants    subset of [ sudo network media serial input ] -- capabilities a
              host turns into groups (lib/registry.nix grantGroups: sudo =
              wheel, network = networkmanager, media = video + audio,
              serial = dialout, input = input). Nothing else gives a person
              a group (features may add accounts to their own).

  `rank` orders the types for transitions: moving a deployed user to a type
  of lower rank is a demotion, refused at switch time (when
  my.registry.recordTypes is on) unless his file says
  acceptTypeChange = "<old>-><new>". See lib/registry.nix `transition`.

  Per-user keys that go with some types (registry/users/<name>.nix):
    tmpfsSize         size= of a tmpfs home, default "2G".
    acceptTypeChange  "<old type>-><new type>": consent to one dangerous
                      transition. Inert once the new type is recorded.
    handover          { expires = "YYYY-MM-DD"; } (handover type only): the
                      account's hard end. Its password is never declared:
                      an admin issues one per lending on the machine
                      (`sudo handover issue <user>`, features/core/users/
                      handover.nix).

  `overridable` is per type and deliberately short. An override outside it is
  an error, not a silent no-op: a "member" whose file says nix = admin is an
  admin with a misleading label, and the label is what people read.

  NIX TRUST. nix = "none" drives allowed-users; trusted-users is exactly the
  host's nix = "admin" accounts (plus root and
  my.registry.nix.extraTrustedUsers), and every other registry user is
  asserted absent from it. No preset is nix = "admin" any more: today
  trusted-users is root (plus nix-ssh on a builder). A person who needs
  trust says overrides.nix = "admin" in his file (admin type only).
*/
{
  # Admin through sudo, not through the daemon: untrusted like everyone else
  # (a trusted user is root-equivalent to the store without a password).
  # Builders still serve him -- the daemon dispatches for every client -- he
  # just cannot name his own; root can (sudo nix build --builders ...).
  admin = {
    home = "persistent";
    nix = "untrusted";
    session = "home-manager";
    builders = false;
    grants = [ "sudo" "network" "media" ];
    rank = 3;
    overridable = [ "home" "nix" "builders" "session" "grants" ];
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
  # Which program is the only thing a handover user may choose; whatever the
  # greeter offers, the login runs that program (kiosk.nix pins it).
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
