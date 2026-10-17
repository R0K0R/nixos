/*
  my.tuning in a HOME: which package set this user's home is built from, and
  per-package levers inside it. docs/multiuser-design.md, "Per-user tuning".

  Read by homeLib.<host>.mkHome before the package set exists -- it defines
  `_module.args.pkgs` from this option (lib/user-tuning.nix) -- so every
  definition must be a literal that does not read `pkgs`: anything else is
  infinite recursion, exactly as with home-manager's own nixpkgs module.

  In every home (sharedModules), so a user module may always set it; only a
  standalone home (homeActivation = "standalone") may set it to anything but
  the defaults -- an integrated home is built from the system's set by the
  system (lib/home-manager.nix asserts it).
*/
{ lib, ... }:

let
  lever =
    what:
    lib.mkOption {
      type = lib.types.either (lib.types.enum [ "system" ]) lib.types.bool;
      default = "system";
      description = ''
        The ${what} lever of this home's package set: "system" (whatever the
        host does), true or false.
      '';
    };
  names =
    what:
    lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = what;
    };
in
{
  options.my.tuning = {
    march = lib.mkOption {
      type = lib.types.either lib.types.bool lib.types.str;
      default = "system";
      example = "znver3";
      description = ''
        "system" (whatever the host does), false (no march: plain upstream
        nixpkgs underneath, unless lto/o3 tune it natively), true (the host's
        own march -- an error on a host without one), or a gcc arch.
      '';
    };
    lto = lever "lto";
    o3 = lever "o3";

    packages = {
      o3 = names ''
        Top-level package names to build with -O3 in THIS user's set, whether
        or not the classifier counts them as host-runtime (and, under march,
        never substituted from upstream). Needs o3 on in this set.'';
      lto = names "As packages.o3, for the lto lever.";
    };
    exclude = {
      o3 = names "Names the o3 lever must not touch in this user's set (added to the host's own exclusions).";
      lto = names "As exclude.o3, for the lto lever.";
    };
  };
}
