/*
  Which people live on which machine, and the cross-host facts other parts of
  the registry (and user repos, via homeLib facts) need without evaluating a
  NixOS configuration.

  hosts.<host>
    users    names from registry/users/. Listing one creates the account;
             there is no enable, same as my.users.
    primary  the account features default to (my.<feature>.users). Per host,
             because "whose machine is this" is a property of the machine.
    groups   <user> -> concrete groups ON THIS HOST, replacing the user file's
             `groups`. The list is written out in full and in the order it
             always had: a definition replaces my.users' default (listing only
             "dialout" would silently drop wheel and sudo with it), and
             reordering would rewrite users-groups.json.
    narrow   <user> -> axes to narrow on this host (never widen): builders
             true -> false, grants to a subset, nix to a lower rank. Plus
             `localBuilds = false`, accepted only where the host builds
             nothing locally anyway (Nix has no per-user max-jobs; see
             lib/registry.nix). Unused today.

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
      # dialout is for arduino-cli/arduino-ide (/dev/ttyACM*, /dev/ttyUSB*).
      groups.r0k0r = [ "wheel" "networkmanager" "video" "audio" "dialout" ];
    };

    victus-15 = {
      # Both humans. benjamin gets an account and a home-manager configuration,
      # but none of the features scoped to the primary unless he is named
      # explicitly.
      users = [ "r0k0r" "benjamin" ];
      primary = "r0k0r";
      groups.r0k0r = [ "networkmanager" "wheel" ];
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

    yulee = {
      managed = false;
      builder = true;
      builderClient = false;
    };
  };
}
