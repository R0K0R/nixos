/*
  A guest account on galaxybook4-pro360: the `untrusted` preset -- no store
  access, the system's default session, no groups. Its own persistent home
  (bound whole from /persist on the impermanent laptop).

  No password: anyone at the keyboard may use it, and it can do nothing
  with that (no sudo, no store, no groups).
*/
{
  uid = 1002;
  type = "untrusted";
  description = "Guest";
  passwordless = true;
}
