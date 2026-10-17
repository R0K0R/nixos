/*
  One file per person, ever. Removing someone means `removed = true;` and
  keeping the file: the uid stays reserved (lib/registry.nix refuses a reuse),
  because files on disk and in backups still carry it.

  shell is a package ATTRIBUTE NAME, not a package -- this file is plain data
  and has no pkgs. The host's own pkgs resolves it (pkgs.zsh), which is the same
  derivation the host file used to name directly.
*/
{
  uid = 1000;
  type = "admin";
  shell = "zsh";
  # One account, one password: the same secret on every host r0k0r lives on.
  # It was an untracked /etc/nixos/secrets/hashed-password-r0k0r before agenix
  # -- and on galaxybook that file did not even exist (mutableUsers = true meant
  # the live shadow entry carried the password and the gap went unnoticed).
  passwordSecret = ../../age/hashed-password-r0k0r.age;
  # His home is activated by his own repo (~/config/home, github:R0K0R/home)
  # with `home-manager switch --flake ~/config/home`, not by system switches.
  homeActivation = "standalone";
  # Public keys that may log in as him, on every NixOS host he lives on
  # (users.users.<n>.openssh.authorizedKeys). His own key, never the builder
  # key: that one is root's.
  sshKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFwL82rZ5NXi7aCit68eSSmeHjmZQlHu/PYK5e0f6Ysx r0k0r@galaxybook4-pro360" ];
  # serial (dialout) for arduino-cli/arduino-ide (/dev/ttyACM*, /dev/ttyUSB*).
  # victus-15 narrows this to sudo + network (registry/hosts.nix).
  overrides.grants = [ "sudo" "network" "media" "serial" ];
}
