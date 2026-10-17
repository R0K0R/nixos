/*
  The registry's nix axis, as far as the daemon can enforce it per user (the
  full argument is in lib/registry.nix's header). Two lists exist:

    allowed-users   who may connect at all. nix = "none" is left out.
    trusted-users   who may pass privileged settings. WRITTEN from the
                    registry: every account with nix = "admin", plus
                    my.registry.nix.extraTrustedUsers. NixOS adds root. Host
                    files no longer name people here. nix = "none" and
                    "untrusted" are still asserted absent, because an extra
                    entry (a name, "*", an @group) could trust one anyway.

  Making an admin untrusted is a registry edit (type, or a narrow on one
  host), not a host-file edit -- which is the point: the type is what people
  read, so it is what decides.

  ALLOWED-USERS IS ONLY WRITTEN WHEN SOMEONE IS EXCLUDED. Its NixOS default
  is [ "*" ], and replacing that with an explicit list on every host would
  rewrite nix.conf (and the toplevel) for no change in behaviour. A host with
  a nix = "none" account gets: root, every account that is not "none" (hand-
  written my.users entries included, they were allowed before), and
  my.registry.nix.extraAllowedUsers for service accounts that talk to the
  daemon. Trusted users are always allowed by Nix itself.

  What nix = "none" does NOT do: hide the store. /nix/store is world-readable
  and its programs world-executable; the user just cannot ask the daemon to
  build, substitute, or add a gcroot.
*/
{ config, lib, ... }:

let
  users = config.my.users;
  excluded = lib.attrNames (lib.filterAttrs (_: u: u.nix == "none") users);
  admins = lib.attrNames (lib.filterAttrs (_: u: u.nix == "admin") users);
  untrustedish = lib.filterAttrs (_: u: u.nix == "none" || u.nix == "untrusted") users;

  trusted = config.nix.settings.trusted-users or [ ];
  groupsOf = n: [ config.users.users.${n}.group ] ++ config.users.users.${n}.extraGroups;
  trustedVia =
    n:
    lib.optional (lib.elem n trusted) n
    ++ lib.optional (lib.elem "*" trusted) "*"
    ++ lib.filter (g: lib.elem "@${g}" trusted) (groupsOf n);
in
{
  options.my.registry.nix.extraTrustedUsers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "@nixbuilders" ];
    description = ''
      trusted-users entries that are not registry people (service accounts,
      groups). Registry users get trust from nix = "admin" only; naming a
      non-admin one here fails the nix-access assertion.
    '';
  };

  options.my.registry.nix.extraAllowedUsers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "hydra" "@nix-serve" ];
    description = ''
      Extra allowed-users entries (users, or @groups) for system accounts that
      connect to the daemon. Only used on a host where some account has
      nix = "none" -- elsewhere allowed-users stays at its default "*".
    '';
  };

  config = {
    nix.settings.trusted-users = admins ++ config.my.registry.nix.extraTrustedUsers;

    nix.settings.allowed-users = lib.mkIf (excluded != [ ]) (
      [ "root" ]
      ++ lib.attrNames (lib.filterAttrs (_: u: u.nix != "none") users)
      ++ config.my.registry.nix.extraAllowedUsers
    );

    assertions = lib.mapAttrsToList (n: u: {
      assertion = trustedVia n == [ ];
      message = ''
        my.users.${n} has nix = "${u.nix}" in the registry, but nix.settings.trusted-users
        trusts it (via ${lib.concatStringsSep ", " (trustedVia n)}). A trusted user can
        pass any setting to the daemon -- builders, substituters, sandbox -- which is
        exactly what nix = "${u.nix}" says it cannot.'';
    }) untrustedish;
  };
}
