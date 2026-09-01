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

  options.my.samsung-galaxybook.speakerFix = lib.mkOption {
    type = lib.types.enum [ "kernel" "dkms" ];
    default = "kernel";
    description = ''
      How to drive the four MAX98390 speaker amps.

      "kernel" carries thesofproject/linux PR #5616 as a kernel patch. This is
      the whole fix: the alc269 quirk, serial-multi-instantiate enumeration and
      the exported regmap all land in tree alongside the driver.

      "dkms" is the out-of-tree module the upstream project ships, kept as a
      fallback for when a kernel bump breaks the patch.

      PREFER "kernel", and the reason is power. The DKMS module cannot provide
      the alc269 quirk, so no HDA component MASTER is ever created; the
      driver's component never completes and its playback hook is never
      called. It compensates by enabling the amps at probe -- leaving four
      class-D amps powered on permanently, whether or not anything is playing.
      In tree, the master binds, the hook fires, and the amps idle properly.
      The same missing quirk is why the ALC298 never gets its correct mixer
      levels, which is the other half of the thin sound.

      COSTS NOTHING EXTRA HERE. A tuned host builds its kernel from source
      already -- linux-x86_64-unknown-linux-gnu-7.1.9 is a 404 on
      cache.nixos.org -- so patching only changes what goes into a build that
      was happening regardless. On an untuned host this would turn a
      substituted kernel into a source build, which is why it is an option
      rather than unconditional.
    '';
  };

  options.my.samsung-galaxybook.enable = lib.mkEnableOption ''
    Samsung Galaxy Book4 Pro 360 hardware support: speakers, internal mic,
    IPU6 webcam, and the ACPI/kernel-param workarounds this chassis needs
  '';
}
