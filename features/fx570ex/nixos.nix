{ config, lib, pkgs, ... }:

let
  cfg = config.my.fx570ex;

  fx570ex = pkgs.callPackage ./package.nix { };
in
{
  options.my.fx570ex.enable = lib.mkEnableOption ''
    fx-570EX, a Casio ClassWiz style scientific calculator

    Built from source in this directory -- see package.nix for why this is a
    reimplementation rather than the accurate route of running the real
    firmware under an nX-U8 emulator
  '';

  # Accounts this feature applies to; defaults to the primary user.
  options.my.fx570ex.users = import ../../lib/user-scope.nix { inherit lib config; };

  options.my.fx570ex.package = lib.mkOption {
    type = lib.types.package;
    default = fx570ex;
    defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
    description = ''
      The calculator build to install.

      Overridable so a host can point at a working tree instead of the vendored
      copy, which is the one thing this feature cannot do on its own -- the
      source is `lib.fileset`-pinned to this directory:

        my.fx570ex.package = pkgs.callPackage ./package.nix { } |> (p:
          p.overrideAttrs { src = /home/r0k0r/git_shit/scientific_calculator_qt; });
    '';
  };

  /*
    A per-user package rather than environment.systemPackages, unlike
    features/kakaotalk which installs system-wide. A calculator is a personal
    tool with no system-level component -- no udev rules, no services, no
    setuid helper -- so there is nothing that wants it on root's PATH, and
    routing through perUser means the `users` option above scopes it the same
    way it scopes every other user-facing feature.
  */
  config = lib.mkIf cfg.enable {
    my.packages.perUser = lib.genAttrs cfg.users (_: [ cfg.package ]);
  };
}
