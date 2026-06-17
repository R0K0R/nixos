{ ... }:

{
  # r0k0r needs flamenco group membership so the SSHFS client (connecting as r0k0r)
  # can write into /var/lib/flamenco-manager/shared (owned flamenco:flamenco 0775).
  users.users.r0k0r.extraGroups = [ "flamenco" ];

  users.users.r0k0r.openssh.authorizedKeys.keys = [
    (builtins.readFile ./flamenco-mount.pub)
  ];
}
