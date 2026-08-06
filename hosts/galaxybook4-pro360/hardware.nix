{ pkgs, ... }:

{
  boot.kernelParams = [
    "intel_pstate=active"
    "sched_itmt_enabled=1"
    "nvme.noacpi=1"
  ];

  # i915 (not xe) for the Xe-LPG iGPU (8086:7d55). We ran xe before, but xe's
  # GuC TLB-invalidation path times out on Meteor Lake -- the kernel logs
  # `[drm] *ERROR* TLB invalidation fence timeout` and the GPU stalls for the
  # whole timeout window, which shows up as compositor stutter (scrolling,
  # workspace switches). i915's MTL support is mature by kernel 7.1 and doesn't
  # hit that bug. force_probe=7d55 still enables the iGPU on this kernel build;
  # blacklist xe so it doesn't grab the device first.
  #
  # PSR left on (kept for the idle-battery saving): the `CPU pipe A FIFO
  # underrun` / `Selective fetch area calculation failed` display glitches were
  # rare and may be xe-side anyway -- revisit enable_psr=0 only if they recur
  # under i915.
  boot.initrd.kernelModules = [ "i915" ];
  boot.blacklistedKernelModules = [ "xe" ];
  boot.extraModprobeConfig = "options i915 force_probe=7d55";

  # Fast compressed-RAM swap. Cold anonymous pages compress into zram (higher
  # priority) instead of faulting off the disk /swapfile; that swapfile
  # (modules/nixos/system/swapfile-btrfs.nix) stays as low-priority overflow
  # for the memory-hungry LTO builds. zram only uses RAM proportional to what's
  # actually stored, so it's free when memory is idle.
  zramSwap.enable = true;

  # Swap application pages out less eagerly. The default of 60 pushed ~7 GB of
  # cold anon pages onto the disk swapfile during heavy builds; touching them
  # again on a workspace switch / scroll faulted them back from disk and
  # stuttered. Reclaim page cache before swapping anon.
  boot.kernel.sysctl."vm.swappiness" = 10;

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

  # Autorotate: iio:device2 (accel_3d) + iio:device3 (hinge) are present
  # (checked via /sys/bus/iio/devices). iio-sensor-proxy publishes orientation
  # over D-Bus; iio-hyprland (wayland/hyprland.nix exec-once) consumes it to
  # rotate the eDP-1 output and touch input transform automatically.
  hardware.sensor.iio.enable = true;

  /*
    Fingerprint sensor is USB 1c7a:05a1 (Egis Technology "Match-On-Chip"),
    checked via sysfs idVendor/idProduct under /sys/bus/usb/devices. Already natively
    supported by libfprint's egismoc driver (device table entry confirmed in
    libfprint 1.94.10 source) — no patched libfprint needed, unlike the
    Focaltech (2808:6553) fix floating around for other Book4 variants, which
    doesn't apply to this sensor at all. Just needed enabling; fprintAuth
    defaults to true for every PAM service (login/sudo/greetd/...) once this
    is on.
  */
  services.fprintd.enable = true;
}
