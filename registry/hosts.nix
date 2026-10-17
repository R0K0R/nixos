/*
  Which people live on which machine, and the cross-host facts other parts of
  the registry (and user repos, via homeLib facts) need without evaluating a
  NixOS configuration.

  hosts.<host>
    users    names from registry/users/. Listing one creates the account;
             there is no enable, same as my.users.
    primary  the account features default to (my.<feature>.users). Per host,
             because "whose machine is this" is a property of the machine.
    localPasswords
             accounts whose password this host keeps for itself (set with
             passwd, users.mutableUsers left at its default) instead of using
             the registry's passwordSecret. A secret is encrypted to particular
             hosts' keys (age/ + secrets.nix); a host that is not a recipient
             cannot decrypt it, and agenix would then fail at activation. The
             account's other axes are unchanged.
    narrow   <user> -> axes to narrow on this host (never widen): builders
             true -> false, grants to a subset, nix to a lower rank. Plus
             `localBuilds = false`, accepted only where the host builds
             nothing locally anyway (Nix has no per-user max-jobs; see
             lib/registry.nix). Groups follow grants (lib/registry.nix
             grantGroups), so narrowing grants is how a host takes a group
             away.

  features.<host>
    Facts, not switches: what is TRUE of each machine, readable from anywhere.
    The switches are still my.* in hosts/<host>/default.nix; if one of these
    stops matching its switch it is this file that is wrong. yulee is listed
    because it is a builder everyone dispatches to, although it is an Ubuntu
    box this flake does not manage.

    localBuilds   the daemon's max-jobs is not 0 -- it builds on this CPU for
                  every user it accepts. Asserted against nix.settings.max-jobs
                  (lib/registry-users.nix), since homeLib facts report it as
                  what a user's builds do.
*/
{
  hosts = {
    galaxybook4-pro360 = {
      users = [ "r0k0r" ];
      primary = "r0k0r";
    };

    victus-15 = {
      # Both humans. benjamin gets an account, but his home is activated by his
      # own repo (homeActivation = "standalone") and none of the features
      # scoped to the primary reach him unless he is named explicitly.
      users = [ "r0k0r" "benjamin" ];
      primary = "r0k0r";
      # Headless builder: no media, no serial devices.
      narrow.r0k0r.grants = [ "sudo" "network" ];
      # He is an admin (it is his machine, dell-latitude) but a guest here as
      # far as groups go: wheel + networkmanager, exactly what he has had on
      # this host all along -- no video/audio on a headless builder.
      narrow.benjamin.grants = [ "sudo" "network" ];
    };

    # benjamin's own machine. His account's password is his own: the secret in
    # age/ is encrypted to victus-15 only, which dell-latitude is not.
    dell-latitude = {
      users = [ "benjamin" ];
      primary = "benjamin";
      localPasswords = [ "benjamin" ];
    };
  };

  features = {
    galaxybook4-pro360 = {
      managed = true;
      # Dispatches to yulee and victus-15 (my.remote-builder.client) and
      # substitutes from both over ssh-ng.
      builder = false;
      builderClient = true;
      # max-jobs = 0: the no-local-builds rule, a host policy for everyone.
      localBuilds = false;
      ccache = true;
      ca-derivations = true;
      guest-overlay = false;
      impermanence = false;
    };

    victus-15 = {
      managed = true;
      # Headless, closed-lid remote builder; also the ccache builder half
      # (my.ccache.builder) with yulee as a read-only peer.
      builder = true;
      builderClient = false;
      localBuilds = true;
      ccache = true;
      ca-derivations = true;
      guest-overlay = false;
      impermanence = false;
    };

    dell-latitude = {
      managed = true;
      builder = false;
      # Dispatches to yulee and victus-15 (my.remote-builder.client).
      builderClient = true;
      # max-jobs = 0, set by the remote-builder client: nothing builds here.
      localBuilds = false;
      ccache = false;
      ca-derivations = false;
      guest-overlay = false;
      impermanence = false;
    };

    yulee = {
      managed = false;
      builder = true;
      builderClient = false;
    };
  };
}
