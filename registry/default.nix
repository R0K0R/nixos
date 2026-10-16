/*
  Loads registry/ and runs lib/registry.nix's checks over it. Imported by
  flake.nix (the `registry` output, homeLib facts) and by the NixOS side
  (lib/registry-users.nix), each with its own nixpkgs lib -- the result is pure
  data, so which lib does the arithmetic does not matter.

  users/ is a readDir walk for the same reason features/ is: no list to forget
  to update. The file name IS the user name.
*/
{ lib }:

let
  userFiles = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) (
    builtins.readDir ./users
  );
in
(import ../lib/registry.nix { inherit lib; }).load {
  users = lib.mapAttrs' (
    f: _: lib.nameValuePair (lib.removeSuffix ".nix" f) (import (./users + "/${f}"))
  ) userFiles;
  types = import ./types.nix;
  hosts = import ./hosts.nix;
}
