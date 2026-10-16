# Samsung Galaxy Book4 Pro 360 — speakers + internal mic.
# https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes
# Webcam: see webcam.nix
#
# We do NOT import the upstream samsung-speaker-fix.nix NixOS module because it builds
# max98390-hda without passing CC= to make. In a cross build the kernel Makefile
# defaults to CC=$(CROSS_COMPILE)gcc with CROSS_COMPILE empty, calling bare 'gcc' which
# is absent from the sandbox. We replicate the module's config here with the fix.

{ inputs, lib, config, pkgs, ... }:

let
  fixes = inputs.feat-samsung-galaxybook.fixes;
  kernelPackages = config.boot.kernelPackages;
  kernel = kernelPackages.kernel;
  kernelUsesClang = kernel.stdenv.cc.isClang or false;
  isCross = !pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;

  max98390-hda = (kernelPackages.callPackage "${fixes}/nixos/max98390-hda-module.nix" {
    sourceType = "local";
    localSrc = "${fixes}/speaker-fix/src";
  }).overrideAttrs (old: lib.optionalAttrs (!kernelUsesClang && isCross) {
    # The upstream module omits CC= for GCC; the kernel Makefile then calls bare 'gcc'
    # which is not in PATH in a cross sandbox. Pass the prefixed cross compiler explicitly.
    makeFlags = (old.makeFlags or [ ]) ++ [
      "CC=${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}gcc"
    ];
  });

  i2cSetupScript = pkgs.writeShellScript "max98390-hda-i2c-setup" ''
    export PATH="${pkgs.i2c-tools}/bin:$PATH"

    ACTION="''${1:-start}"

    ALL_ADDRS="0x38 0x39 0x3c 0x3d"

    find_i2c_bus() {
      local dev_path parent_name bus_num
      for dev in /sys/bus/i2c/devices/*MAX98390*; do
        [ -e "$dev" ] || continue
        dev_path="$(readlink -f "$dev")"
        parent_name="$(basename "$(dirname "$dev_path")")"
        bus_num="$(echo "$parent_name" | sed -n 's/^i2c-\([0-9]\+\)$/\1/p')"
        if [ -n "$bus_num" ]; then
          echo "$bus_num"
          return 0
        fi
        bus_num="$(echo "$dev_path" | sed -n 's|.*/i2c-\([0-9]\+\)/.*|\1|p')"
        if [ -n "$bus_num" ]; then
          echo "$bus_num"
          return 0
        fi
      done
      for acpi in /sys/bus/acpi/devices/MAX98390:*; do
        [ -e "$acpi/physical_node" ] || continue
        dev_path="$(readlink -f "$acpi/physical_node")"
        parent_name="$(basename "$(dirname "$dev_path")")"
        bus_num="$(echo "$parent_name" | sed -n 's/^i2c-\([0-9]\+\)$/\1/p')"
        if [ -n "$bus_num" ]; then
          echo "$bus_num"
          return 0
        fi
        bus_num="$(echo "$dev_path" | sed -n 's|.*/i2c-\([0-9]\+\)/.*|\1|p')"
        if [ -n "$bus_num" ]; then
          echo "$bus_num"
          return 0
        fi
      done
      return 1
    }

    find_present_addrs() {
      local bus="$1" addr present=""
      for addr in $ALL_ADDRS; do
        [ "$addr" = "0x38" ] && continue
        if [ -e "/sys/bus/i2c/devices/''${bus}-00''${addr#0x}" ]; then
          continue
        fi
        if i2cget -y "$bus" "$addr" 0x00 b >/dev/null 2>&1; then
          present="$present $addr"
        fi
      done
      echo "$present"
    }

    BUS=$(find_i2c_bus)
    if [ -z "$BUS" ]; then
      echo "max98390-hda: No MAX98390 ACPI device found on I2C bus" >&2
      exit 0
    fi

    SYSFS="/sys/bus/i2c/devices/i2c-''${BUS}"

    case "$ACTION" in
      start)
        ADDRS=$(find_present_addrs "$BUS")
        if [ -z "$ADDRS" ]; then
          echo "max98390-hda: No additional amplifiers found on bus $BUS"
        else
          count=$(echo "$ADDRS" | wc -w)
          echo "max98390-hda: Found $count additional amplifier(s) on bus $BUS:$ADDRS"
          for addr in $ADDRS; do
            echo "max98390-hda $addr" > "$SYSFS/new_device" 2>/dev/null || true
          done
        fi
        ;;
      stop)
        for addr in 0x3d 0x3c 0x39; do
          echo "$addr" > "$SYSFS/delete_device" 2>/dev/null || true
        done
        ;;
    esac
  '';
in
lib.mkIf config.my.samsung-galaxybook.enable (
  lib.mkMerge [
    /*
      IN-TREE: carry PR #5616 as a kernel patch. See the option's description
      in ./nixos.nix for why this is preferred, and the patch header for what
      each of the five pieces does.

      MODULAR, not built in -- it cannot be otherwise. The I2C entry selects
      SND_SOC_MAX98390, which the config phase offers only as N/m, so asking
      for =y fails outright:

        QUESTION: ... SND_HDA_SCODEC_MAX98390_I2C, ALTS: N/m/?, ANSWER: y
        error: builder ... failed with exit code 255

      Because it is modular, the Kconfig's own note applies -- auto-loading
      wants SND_HDA=y, which is not the case here -- so the modules are named
      explicitly below rather than left to udev.

      serial-multi-instantiate still enumerates all four amps by itself once it
      knows the ACPI ID, which is what makes the hand-rolled I2C sysfs service
      in the dkms path unnecessary.
    */
    (lib.mkIf (config.my.samsung-galaxybook.speakerFix == "kernel") {
      boot.kernelPatches = [
        {
          name = "max98390-hda-scodec";
          patch = ./max98390-hda.patch;
          structuredExtraConfig = with lib.kernel; {
            # The I2C entry selects SND_HDA_SCODEC_MAX98390 and SND_SOC_MAX98390
            # itself; setting it is enough to pull the whole chain in.
            SND_HDA_SCODEC_MAX98390_I2C = module;
          };
        }
      ];

      boot.kernelModules = [
        "snd-hda-scodec-max98390"
        "snd-hda-scodec-max98390-i2c"
      ];
    })

    /*
      OUT-OF-TREE fallback: the upstream project's DKMS module, plus the
      systemd unit that creates the three I2C devices ACPI does not enumerate.
      Kept so a kernel bump that breaks the patch is a one-line change rather
      than a revert.
    */
    (lib.mkIf (config.my.samsung-galaxybook.speakerFix == "dkms") {
      boot.extraModulePackages = [ max98390-hda ];

      boot.kernelModules = [
        "i2c-dev"
        "snd-hda-scodec-max98390"
        "snd-hda-scodec-max98390-i2c"
      ];

      environment.systemPackages = [ pkgs.i2c-tools ];

      systemd.services.max98390-hda-i2c-setup = {
        description = "Create I2C devices for MAX98390 HDA speaker amplifiers";
        after = [ "systemd-modules-load.service" ];
        before = [ "sound.target" ];
        wantedBy = [ "sound.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${i2cSetupScript} start";
          ExecStop = "${i2cSetupScript} stop";
        };
      };
    })

    # The internal mic is a separate defect from the speakers and is unaffected
    # by which of the two paths above is taken.
    {
      boot.extraModprobeConfig = lib.mkAfter ''
        # Galaxy Book4 internal mic (mic-fix)
        options snd-intel-dspcfg dsp_driver=3
      '';
    }
  ]
)
