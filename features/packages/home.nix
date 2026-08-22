{ config, lib, osConfig, ... }:

let
  /*
    my.packages.extra.home is the HOST's one-off list, and a host has one
    primary. Without this test it would land in every account's home.packages,
    because sharedModules are evaluated once per user -- so adding a second
    human to a machine would silently hand them the first human's extras.

    Scoped to the primary rather than to a `users` option because there is no
    feature here to scope: this is the host escape hatch, and it means the same
    thing as my.packages.extra.user, which also targets the primary. A host that
    wants packages for a NON-primary account writes my.packages.perUser.<name>
    (system) or that user's own home config.
  */
  isPrimary = config.home.username == osConfig.my.internal.primaryUser;
in
lib.mkIf (osConfig.my.packages.extra.home != [ ] && isPrimary) {
  home.packages = osConfig.my.packages.extra.home;
}
