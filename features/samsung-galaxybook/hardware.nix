{ config, lib, pkgs, ... }:

lib.mkIf config.my.samsung-galaxybook.enable {
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

  /*
    Two firmware ACPI bugs on this exact BIOS (NT960QGK, P14RHB.460.250425.04),
    confirmed by dumping/disassembling the live tables (2026-08-07):

    1. `\_SB.PC00.LPCB.FAN0._FST` does `Local1 = FANT[Local0]` then
       `Local1 += 0x0A` -- FANT[Local0] is a package-element Reference, not
       the Integer it looks like, so the addition throws
       AE_AML_OPERAND_TYPE and _FST aborts every boot ("acpi-fan
       PNP0C0B:00: Error retrieving current fan status: -5"). Fixed by
       wrapping in DerefOf(); shipped as a brand-new SSDT (unique OEM
       ID/Table ID, so the kernel *appends* it) that reopens the FAN0
       scope and redefines _FST -- the later-loaded definition wins in the
       ACPI namespace.

    2. `\_SB.IETM._ART` (in the DPTF SSDT, OEM ID "DptfTb"/"DptfTabl")
       unconditionally checks `\_SB.IETM.SEN3.CTYP`, but SEN3 (a third
       thermal sensor) is declared External and never actually defined by
       any loaded table on this model -- unlike the other optional objects
       in the same method, which are all properly guarded with
       CondRefOf(). Aborts _ART with AE_NOT_FOUND every boot. Fixed by
       adding the same CondRefOf() guard, shipped as a full replacement of
       that SSDT with a bumped OEM Revision (0x1000 -> 0x1001; the initrd
       table-upgrade mechanism only replaces a matching table if the
       incoming OEM Revision is strictly higher).

    Both are reporting-only bugs -- the EC still drives the fan curve in
    hardware regardless of what Linux can read -- but they spam dmesg/
    journal every boot, so worth silencing. See acpi/*.dsl for the full
    patched source and rebuild instructions, and
    ../../galaxybook-thermal-findings.md for the investigation writeup.

    Requires CONFIG_ACPI_TABLE_UPGRADE (on by default), and requires
    systemd stage-1 initrd (boot.initrd.systemd.contents is not read by
    the legacy initrd builder).
  */
  boot.initrd.systemd.contents = {
    "/kernel/firmware/acpi/fan-fst-fix.aml".source = ./acpi/fan-fst-fix.aml;
    "/kernel/firmware/acpi/dptf-art-fix.aml".source = ./acpi/dptf-art-fix.aml;
  };

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
  # over D-Bus; iio-hyprland (features/hyprland/home.nix exec-once) consumes it to
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
