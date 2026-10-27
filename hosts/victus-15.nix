/*
  benjamin on victus-15: a headless, closed-lid remote builder, so no desktop.

  Nothing was ever enabled for him here in the old flake -- he has an account for builds and
  shell access, and every user-level feature of the old host file was scoped to its primary user
  (r0k0r). The one thing a login does get is what the system flake's own feature halves give
  every account with a home on this host. Per-host choices for the modules in ../modules go in
  this file if that changes; nothing graphical belongs on it.
*/
{ ... }:

{
  # His fish config (the system keeps fish as a login shell here).
  my.fish.enable = true;
}
