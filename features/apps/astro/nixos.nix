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

  # Accounts this feature applies to; defaults to the primary user.
  options.my.astro.users = import ../../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      my.state.user.state.directories = [
        ".config/siril" # Siril's settings and working directories
      ];
      my.state.user.optional.directories = [
        ".local/share/siril" # Siril's python script venv; pip install to rebuild
        ".local/share/siril-scripts" # the script repository; Siril fetches it again
        ".local/share/siril-spcc-database" # photometric colour database; downloadable
      ];
    }
    (lib.mkIf (pkgSet ? system) { environment.systemPackages = pkgSet.system; })
    # Emitted only when non-empty, and keyed by this feature's `users`
    # scope rather than by a hardcoded account -- see lib/user-scope.nix.
    (lib.mkIf (pkgSet ? user) { my.packages.perUser = lib.genAttrs config.my.astro.users (_: pkgSet.user); })
    # astropy goes into features/python-dev's environment rather than a python
    # of its own; it only lands where python-dev is enabled.
    { my.python-dev.packages = [ (ps: [ ps.astropy ]) ]; }
  ]);
}
