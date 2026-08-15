{ lib, ... }:

{
  /*
    Samsung Galaxy Book4 Pro 360 hardware enablement, in one place:

      fixes.nix     speakers (max98390-hda) + internal mic
      webcam.nix    IPU6 + libcamera
      hardware.nix  kernel params, i915 selection, ACPI table overrides
      acpi/         the compiled ACPI overrides those tables reference

    `imports` cannot be gated, so each file gates its own config on
    my.samsung-galaxybook.enable.

    This is the most portable feature in the repo: between them these files
    reference exactly one external -- inputs.feat-samsung-galaxybook.fixes --
    plus the stock config.boot.kernelPackages. No dependency on any other
    feature, so the directory can be handed to another Galaxy Book owner as-is.
  */
  imports = [
    ./fixes.nix
    ./webcam.nix
    ./hardware.nix
  ];

  options.my.samsung-galaxybook.enable = lib.mkEnableOption ''
    Samsung Galaxy Book4 Pro 360 hardware support: speakers, internal mic,
    IPU6 webcam, and the ACPI/kernel-param workarounds this chassis needs
  '';
}
