/*
  A guest account on galaxybook4-pro360: the `untrusted` preset -- no store
  access, the system's default session, no groups. Its own persistent home
  (bound whole from /persist on the impermanent laptop).

  No password yet: until age/hashed-password-guest.age exists the account
  is locked. Its owner makes it, choosing the password themselves:
    mkpasswd -m yescrypt | age -r "<galaxybook's agenix recipient, secrets.nix>" \
      -o age/hashed-password-guest.age
  then `passwordSecret = ../../age/hashed-password-guest.age;` here.
*/
{
  uid = 1002;
  type = "untrusted";
  description = "Guest";
}
