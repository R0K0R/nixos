{ config, lib, pkgs, ... }:

let
  cfg = config.my.python-dev;

  python = pkgs.python3.withPackages (
    ps:
    [
      ps.numpy
      ps.scipy
      # Per-package CUDA switch: OpenCV's own enableCuda, so python-dev.cuda
      # works without nixpkgs-wide cudaSupport (my.cuda.cudaSupport). With that
      # on, OpenCV would pick CUDA up by itself; the override is then a no-op.
      (if cfg.cuda.enable then ps.opencv4.override { enableCuda = true; } else ps.opencv4)
      ps.pillow
    ]
    ++ lib.optional cfg.cuda.enable ps.cupy
    ++ lib.concatMap (f: f ps) cfg.packages
  );
in
{
  /*
    The one python3 on this machine's PATH, with a scientific base set. Other
    features add to it through `packages` (astro contributes astropy) rather
    than shipping their own python3, which would collide: two
    python3.withPackages envs in one profile each own bin/python3, and only one
    of them is on PATH.

    Everything here is built from this tree's own package set, so every
    addition is a source build.
  */
  options.my.python-dev = {
    enable = lib.mkEnableOption "a python3 with numpy, scipy, OpenCV and Pillow";

    # Accounts this feature applies to; defaults to the primary user.
    users = import ../../lib/user-scope.nix { inherit lib config; };

    packages = lib.mkOption {
      type = lib.types.listOf (lib.types.functionTo (lib.types.listOf lib.types.package));
      default = [ ];
      example = lib.literalExpression "[ (ps: [ ps.astropy ]) ]";
      description = ''
        Extra package selectors, each `ps: [ ... ]` over python3Packages. Other
        features append here; all are merged into the one environment. Ignored
        while python-dev is disabled.
      '';
    };

    cuda.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.my.cuda.enable;
      defaultText = lib.literalExpression "config.my.cuda.enable";
      description = ''
        CUDA inside this python: CuPy, and OpenCV built with its CUDA modules
        (cv2.cuda). Independent of nixpkgs-wide cudaSupport; GPU generations
        come from my.cuda.capabilities. Needs the NVIDIA driver.
      '';
    };
  };

  /*
    CUDA split in two (2026-10-01): features/cuda is the host side -- toolkit,
    capabilities, and the nixpkgs-wide cudaSupport switch -- and this is the
    python side, opted into per package so it works with that switch off.
  */
  config = lib.mkIf cfg.enable (lib.mkMerge [
    { my.packages.perUser = lib.genAttrs cfg.users (_: [ python ]); }

    (lib.mkIf cfg.cuda.enable {
      assertions = [
        {
          assertion = lib.elem "nvidia" config.services.xserver.videoDrivers;
          message = "my.python-dev.cuda needs the NVIDIA driver (services.xserver.videoDrivers = [ \"nvidia\" ]).";
        }
      ];
    })
  ]);
}
