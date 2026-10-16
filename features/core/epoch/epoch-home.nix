/*
  Home-manager module recording, in every home generation, the system epoch it
  was built against: `$generation/epoch` (and `$generation/system-rev`).

  Exported as homeLib.<host>.epochModule and NOT part of homeLib.<host>.modules
  on purpose: the generation directory is part of the activation package, so
  including it by default would change every existing home's derivation the
  day it lands. A user repo opts in by adding it to its modules:

    system.homeLib.${host}.mkHome {
      inherit username;
      modules = [ ./modules system.homeLib.${host}.epochModule ];
    }

  The value is the epoch of the system revision the repo has LOCKED -- the
  homeLib it was evaluated from -- which is exactly what the generation was
  built against. session-epoch-check and hm-rollback read it as data; a
  generation without the file is "unrecorded", not "matching".

  Arguments are filled in by flake.nix (mkHomeLib); this file takes no
  osConfig, so it works the same after the integrated home-manager is gone.
*/
{ lib, epoch, rev }:

{
  home.extraBuilderCommands = ''
    printf '%s' ${lib.escapeShellArg epoch} > $out/epoch
  ''
  + lib.optionalString (rev != null) ''
    printf '%s' ${lib.escapeShellArg rev} > $out/system-rev
  '';
}
