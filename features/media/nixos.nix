{ config, lib, pkgs, ... }:

let
  cfg = config.my.media;

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
  options.my.media.enable = lib.mkEnableOption "video and 3D tooling: ffmpeg, blender, kdenlive, moonlight";

  # Accounts this feature applies to; defaults to the primary user.
  options.my.media.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf (pkgSet ? system) { environment.systemPackages = pkgSet.system; })
    # Emitted only when non-empty, and keyed by this feature's `users`
    # scope rather than by a hardcoded account -- see lib/user-scope.nix.
    (lib.mkIf (pkgSet ? user) { my.packages.perUser = lib.genAttrs config.my.media.users (_: pkgSet.user); })
  ]);
}
