/*
  A guest account on galaxybook4-pro360: the `untrusted` preset -- no store
  access, no groups -- with its session overridden to GNOME, pinned: whatever
  the greeter offers or remembers, a login as guest starts GNOME
  (features/core/users/session-pin.nix, features/session/gnome). Its own
  persistent home (bound whole from /persist on the impermanent laptop).

  No password: anyone at the keyboard may use it, and it can do nothing
  with that (no sudo, no store, no groups).
*/
{
  uid = 1002;
  type = "untrusted";
  description = "Guest";
  passwordless = true;
  overrides.session = { desktop = "gnome"; };
}
