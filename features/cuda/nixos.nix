{ config, lib, pkgs, ... }:

let
  cfg = config.my.cuda;
in
{
  options.my.cuda = {
    enable = lib.mkEnableOption ''
      CUDA on this host: the toolkit (nvcc, CUDA_PATH) and, by default,
      nixpkgs-wide cudaSupport. Needs the NVIDIA driver
    '';

    cudaSupport = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set nixpkgs.config.cudaSupport, the default that ~135 recipes read for
        their own CUDA switch (ffmpeg, gstreamer, obs, blender, hwloc/openmpi,
        onnxruntime, OpenCV, ...). Every such package in the closure is then
        rebuilt with CUDA -- from source in this tree. Off keeps the toolkit and
        per-package opt-ins (my.python-dev.cuda) without that rebuild.
      '';
    };

    capabilities = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "8.6" ];
      description = ''
        Compute capabilities to compile GPU code for; sets
        nixpkgs.config.cudaCapabilities whenever non-empty, even with the
        feature disabled, since it is a fact about the card that any CUDA
        build here (my.python-dev.cuda included) should honour. Empty keeps
        nixpkgs' default, every supported generation, which multiplies the
        build time of anything with real CUDA code in it.
      '';
    };
  };

  /*
    Built from this tree's own package set. The prebuilt route
    (nixpkgs-upstream + cache.nixos-cuda.org) was checked 2026-09-30 and turned
    down: the user wants it built here. Under IntraISACross that took three
    nixpkgs fixes (pr/cuda-nvcc-cross-host-compiler, pr/cupy-cross-host-nvcc,
    pr/cupy-cuda-capabilities).
  */
  config = lib.mkMerge [
    (lib.mkIf (cfg.capabilities != [ ]) {
      nixpkgs.config.cudaCapabilities = cfg.capabilities;
    })

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = lib.elem "nvidia" config.services.xserver.videoDrivers;
          message = "my.cuda needs the NVIDIA driver (services.xserver.videoDrivers = [ \"nvidia\" ]).";
        }
      ];

      nixpkgs.config.cudaSupport = lib.mkIf cfg.cudaSupport true;

      environment.systemPackages = [ pkgs.cudaPackages.cudatoolkit ];

      # What build systems look for. libcuda.so itself is the driver's, from
      # /run/opengl-driver/lib, which the nixpkgs CUDA packages already search.
      environment.variables.CUDA_PATH = "${pkgs.cudaPackages.cudatoolkit}";
    })
  ];
}
