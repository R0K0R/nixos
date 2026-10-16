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
  # Groups are per host (registry/hosts.nix): dialout, video and audio are
  # galaxybook's, for its arduino and media use.
}
