/*
  my.users from registry/, for whichever host this is. A module of its own,
  rather than a mkHost-only specialArg, because TWO evaluations need it:
  mkHost and tuning/runtime-cache/tier2-eval.nix's pass1. pass1 seeing no
  accounts is exactly the silent failure lib/home-manager.nix's header
  describes -- no my.users, no home-manager users, every home.packages entry
  drops out of the Tier 2 anchors and gets built untuned. Both import this file,
  so they cannot drift.

  `hostName` is a specialArg both of them already pass.
*/
{ hostName, lib, pkgs, ... }:

{
  my.users = (import ../registry { inherit lib; }).materialize hostName pkgs;
}
