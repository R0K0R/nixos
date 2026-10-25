/*
  The account galaxybook4-pro360 is lent out on: the `handover` preset --
  a tmpfs home wiped at logout, nothing else -- with the session overridden
  from the preset's kiosk firefox to a GNOME desktop, pinned like the kiosk
  was: whatever the greeter offers or remembers, a login as handoff starts
  GNOME (features/core/users/session-pin.nix, features/session/gnome). Its
  processes, GNOME's user services included, end with its last session
  (logind KillOnlyUsers, the user manager stopping), and the tmpfs home with
  them. Passwordless, so no per-lending credential either: the pinned
  session and the wiped home are the whole protection.
*/
{
  uid = 1003;
  type = "handover";
  description = "Handoff";
  passwordless = true;
  overrides.session = { desktop = "gnome"; };
}
