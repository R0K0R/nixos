{ config, lib, pkgs, ... }:

let
  cfg = config.my.astro;

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
  options.my.astro.enable = lib.mkEnableOption "astrophotography tooling";

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf (pkgSet ? system) { environment.systemPackages = pkgSet.system; })
    # Emitted only when non-empty: an unconditional users.users.r0k0r.packages
    # would half-define the account on a host that has no such user.
    (lib.mkIf (pkgSet ? user) { users.users.r0k0r.packages = pkgSet.user; })
  ]);
}
