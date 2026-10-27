/*
  The SYSTEM half of base: the CLI tools every host wants. gh with the git
  credential helper it writes, and its token, are the home half, my.base in a
  home repo, since 2026-10-27.
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.base;

  /*
    Read here rather than assembled centrally, so this feature installs its own
    packages for anyone who drops the directory into a config that has never
    heard of this repo's conventions. tuning/runtime-cache/lookup.nix reads the
    same file independently for its Tier 3 anchor set -- two consumers, one
    file, no coupling between them.
  */
  pkgSet = import ./packages.nix { inherit pkgs; };
in
{
  options.my.base.enable = lib.mkEnableOption "baseline CLI tools every host wants regardless of role";

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf (pkgSet ? system) { environment.systemPackages = pkgSet.system; })
  ]);
}
