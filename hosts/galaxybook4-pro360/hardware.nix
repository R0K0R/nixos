{ pkgs, ... }:

{
  boot.kernelParams = [
    "intel_pstate=active"
    "sched_itmt_enabled=1"
    "nvme.noacpi=1"
  ];

  # xe driver takes the Xe-LPG iGPU; prevent i915 from claiming it first.
  # force_probe needed because 7d55 (MTL) isn't officially supported in this kernel build.
  boot.initrd.kernelModules = [ "xe" ];
  boot.blacklistedKernelModules = [ "i915" ];
  boot.extraModprobeConfig = "options xe force_probe=7d55";

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver  # iHD — VA-API (Xe support, hardware decode)
      vpl-gpu-rt          # Intel VPL (Video Processing Library)
    ];
  };

  environment.variables = {
    LIBVA_DRIVER_NAME = "iHD";
  };
}
