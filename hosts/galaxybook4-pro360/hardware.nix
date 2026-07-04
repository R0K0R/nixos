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
