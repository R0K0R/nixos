{ config, lib, ... }:

lib.mkIf config.my.flamenco.enable {
  /*
    Keyed off my.flamenco.users rather than a literal account, for two reasons.

    Correctness: `users.users.<n>.extraGroups` DECLARES the user, so naming
    someone who does not exist on this host leaves a half-defined account behind
    -- no isNormalUser, no isSystemUser -- which NixOS rejects outright.

    Meaning: whoever mounts the share is exactly whoever this feature applies
    to. The group grants write access into
    /var/lib/flamenco-manager/shared (flamenco:flamenco 0775), and the key
    authorises the SSHFS client that connects as them. Scoping both to the same
    list is what keeps the two from drifting apart.
  */
  users.users = lib.genAttrs config.my.flamenco.users (_: {
    extraGroups = [ "flamenco" ];
    openssh.authorizedKeys.keys = [
      (builtins.readFile ./flamenco-mount.pub)
    ];
  });
}
