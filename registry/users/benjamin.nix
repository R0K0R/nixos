{
  uid = 1001;
  type = "member";
  description = "Benjamin S.H. Lee";
  shell = "fish";
  passwordSecret = ../../age/hashed-password-benjamin.age;
  # He has had wheel on victus-15 since the account was made. That is a member
  # with sudo, stated as an override rather than by calling him an admin --
  # admin would also say nix = "admin", which he is not (trusted-users is
  # r0k0r only).
  overrides.grants = [ "sudo" "network" ];
  groups = [ "networkmanager" "wheel" ];
}
