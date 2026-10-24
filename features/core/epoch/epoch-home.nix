/*
  Home-manager module recording, in every home generation, the system epoch it
  was built against: `$generation/epoch` (and `$generation/system-rev`).

  Included AUTOMATICALLY in every home built for a host with my.epoch on:
  features/core/epoch adds it to home-manager.sharedModules, which both the
  integrated home-manager and homeLib.<host>.mkHome (lib/home-generator.nix
  takes the system's final sharedModules) evaluate. The guard
  (my.fallback-session.guard) reads this file to decide whether a login gets
  the normal session, so it must not depend on a user repo opting in. On a
  host with the epoch off nothing includes it: the generation directory is
  part of the activation package, and adding a file would move every home
  there for nothing to read it.

  Also exported as homeLib.<host>.epochModule, for a repo that wants it
  explicitly; the `key` makes the module system keep one copy when both
  paths bring it.

  The value is the epoch of the system revision the repo has LOCKED -- the
  homeLib it was evaluated from -- which is exactly what the generation was
  built against. session-epoch-check, guarded-session and hm-rollback read it
  as data; a generation without the file is "unrecorded", not "matching".

  Arguments are filled in by the caller (features/core/epoch, flake.nix
  mkHomeLib); this file takes no osConfig, so it works the same after the
  integrated home-manager is gone.
*/
{ lib, epoch, rev }:

{
  key = "features/core/epoch/epoch-home.nix";
  home.extraBuilderCommands = ''
    printf '%s' ${lib.escapeShellArg epoch} > $out/epoch
  ''
  + lib.optionalString (rev != null) ''
    printf '%s' ${lib.escapeShellArg rev} > $out/system-rev
  '';
}
