{
  uid = 1001;
  # An admin: dell-latitude is his machine, and he has had sudo on victus-15
  # since the account was made. victus-15 narrows the grants back to what he
  # has there (registry/hosts.nix narrow.benjamin) -- a host narrows, the type
  # says what he is.
  type = "admin";
  description = "Benjamin S.H. Lee";
  shell = "fish";
  # Used where this host has agenix and he is a recipient (victus-15). A host
  # that keeps his password local says so (hosts.nix localPasswords).
  passwordSecret = ../../age/hashed-password-benjamin.age;
  # His home is activated by his own repo (a standalone home-manager
  # configuration on this flake's homeLib), not by system switches.
  homeActivation = "standalone";
}
