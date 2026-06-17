# Galaxy Book4 Pro 360 — IPU6 + libcamera (webcam-fix-libcamera).
# Ports upstream install.sh + patterns from nixos/webcam-fix-book5.nix.
# https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes

{ inputs, config, lib, pkgs, ... }:

let
  fixes = inputs.samsung-galaxy-book-linux-fixes;
  kernelPackages = config.boot.kernelPackages;
  kernel = kernelPackages.kernel;
  kernelUsesClang = kernel.stdenv.cc.isClang or false;
  isCross = !pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
  cc = if kernelUsesClang then pkgs.llvmPackages.clang-unwrapped else pkgs.stdenv.cc;
  clangMakeFlags =
    lib.optionalString kernelUsesClang "LLVM=1 CC=${cc}/bin/clang LD=${pkgs.llvmPackages.lld}/bin/ld.lld";
  # In cross builds the kernel Makefile defaults to CC=$(CROSS_COMPILE)gcc with empty
  # CROSS_COMPILE, falling back to bare 'gcc' which is not in PATH. Pass CC explicitly.
  gccMakeFlags =
    lib.optionalString (!kernelUsesClang && isCross) "CC=${cc}/bin/${pkgs.stdenv.cc.targetPrefix}gcc";

  ivscModules = [
    "mei-vsc"
    "mei-vsc-hw"
    "ivsc-ace"
    "ivsc-csi"
  ];

  ipuBridgeModule = pkgs.stdenvNoCC.mkDerivation {
    pname = "ipu-bridge-fix";
    version = "1.4-${kernel.modDirVersion}";
    src = "${fixes}/webcam-fix-book5/ipu-bridge-fix";
    nativeBuildInputs = [ kernel.dev cc pkgs.gnumake pkgs.perl ]
      ++ lib.optionals kernelUsesClang [ pkgs.llvmPackages.lld ];
    buildPhase = ''
      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
        M=$PWD modules ${clangMakeFlags} ${gccMakeFlags}
    '';
    installPhase = ''
      install -Dm644 ipu-bridge.ko $out/lib/modules/${kernel.modDirVersion}/extra/ipu-bridge.ko
    '';
    meta = with lib; {
      description = "Samsung ipu-bridge rotation fix (Galaxy Book4 360 / NP960QGK)";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };

  cameraRelayMonitor = pkgs.stdenv.mkDerivation {
    pname = "camera-relay-monitor";
    version = "1.0";
    src = "${fixes}/camera-relay";
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      $CC -O2 -Wall -o camera-relay-monitor camera-relay-monitor.c
    '';
    installPhase = ''
      install -Dm755 camera-relay-monitor $out/bin/camera-relay-monitor
    '';
  };

  cameraRelayRuntimeInputs = with pkgs; [
    bash
    coreutils
    findutils
    gawk
    gnugrep
    gnused
    kmod
    procps
    systemd
    util-linux
    libcamera
    v4l-utils
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
  ];

  cameraRelay = pkgs.stdenvNoCC.mkDerivation {
    pname = "camera-relay";
    version = "1.0";
    src = "${fixes}/camera-relay";
    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontConfigure = true;
    dontFixup = true;
    installPhase = ''
      install -Dm755 camera-relay $out/share/camera-relay/camera-relay
      substituteInPlace $out/share/camera-relay/camera-relay \
        --replace "/usr/local/bin/camera-relay-monitor" "${cameraRelayMonitor}/bin/camera-relay-monitor" \
        --replace "/usr/local/bin/camera-relay" "$out/bin/camera-relay"
      mkdir -p $out/bin
      makeWrapper $out/share/camera-relay/camera-relay $out/bin/camera-relay \
        --prefix PATH : ${lib.makeBinPath cameraRelayRuntimeInputs} \
        --set LIBCAMERA_IPA_MODULE_PATH ${pkgs.libcamera}/lib/libcamera/ipa \
        --prefix GST_PLUGIN_PATH : ${lib.makeSearchPath "lib/gstreamer-1.0" [ pkgs.libcamera ]} \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.libcamera ]}
    '';
  };

  libcameraEnv = {
    LIBCAMERA_IPA_MODULE_PATH = "${pkgs.libcamera}/lib/libcamera/ipa";
    GST_PLUGIN_PATH = lib.makeSearchPath "lib/gstreamer-1.0" [ pkgs.libcamera ];
    LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.libcamera ];
  };

  wireplumberLuaRule = ''
    rule = {
      matches = {
        {
          { "node.name", "matches", "v4l2_input.pci-0000_00_05*" },
        },
      },
      apply_properties = {
        ["node.disabled"] = true,
      },
    }
    table.insert(v4l2_monitor.rules, rule)
  '';

  wireplumberConfRule = ''
    monitor.v4l2.rules = [
      {
        matches = [
          { node.name = "~v4l2_input.pci-0000_00_05*" }
        ]
        actions = {
          update-props = {
            node.disabled = true
          }
        }
      }
    ]
  '';

  wireplumberUsesConf = lib.versionAtLeast (pkgs.wireplumber.version or "0.5") "0.5";
in
{
  nixpkgs.overlays = [
    (final: prev: {
      libcamera = prev.libcamera.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          HELPER_FILE=""
          for candidate in src/ipa/libipa/camera_sensor_helper.cpp \
                           src/libcamera/sensor/camera_sensor_helper.cpp; do
            if [ -f "$candidate" ]; then
              HELPER_FILE="$candidate"
              break
            fi
          done
          if [ -n "$HELPER_FILE" ]; then
            if ! grep -q 'CameraSensorHelperOv02c10' "$HELPER_FILE"; then
              sed -i '/#endif.*__DOXYGEN__/i\
          class CameraSensorHelperOv02c10 : public CameraSensorHelper\
          {\
          public:\
          \tCameraSensorHelperOv02c10()\
          \t{\
          \t\tgain_ = AnalogueGainLinear{ 1, 0, 0, 16 };\
          \t}\
          };\
          REGISTER_CAMERA_SENSOR_HELPER("ov02c10", CameraSensorHelperOv02c10)\
          ' "$HELPER_FILE"
            fi
          fi
        '';
        postInstall = (old.postInstall or "") + ''
          install -Dm644 ${fixes}/webcam-fix-libcamera/ov02c10.yaml \
            $out/share/libcamera/ipa/simple/ov02c10.yaml
        '';
      });
    })
  ];

  boot.initrd.kernelModules = ivscModules;

  boot.kernelModules = ivscModules ++ [
    "ipu-bridge"
    "v4l2loopback"
  ];

  boot.extraModulePackages = [
    ipuBridgeModule
    kernelPackages.v4l2loopback
  ];

  environment.systemPackages = [
    cameraRelay
    pkgs.libcamera
    pkgs.v4l-utils
  ];

  environment.sessionVariables = libcameraEnv;

  users.users.r0k0r.extraGroups = [ "kvm" ];

  programs.firefox.preferences = {
    "media.webrtc.camera.allow-pipewire" = true;
  };

  # Do not use environment.etc for udev/rules.d/* — systemd already owns etc/udev/rules.d
  # as a symlink tree; nesting another rules file there fails on remote builders.
  services.udev.extraRules = lib.mkAfter ''
    SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="Intel IPU6 ISYS Capture*", TAG-="uaccess"
    SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="Intel IPU6 CSI2*", TAG-="uaccess"
  '';

  environment.etc = {
    "modules-load.d/ivsc.conf".text = lib.concatStringsSep "\n" ivscModules + "\n";

    "modprobe.d/ivsc-camera.conf".text = ''
      softdep ov02c10 pre: mei-vsc mei-vsc-hw ivsc-ace ivsc-csi
    '';

    "modprobe.d/99-camera-relay-loopback.conf".text = ''
      options v4l2loopback devices=1 exclusive_caps=0 card_label="Camera Relay"
    '';
  }
  // lib.optionalAttrs wireplumberUsesConf {
    "wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf".text = wireplumberConfRule;
  }
  // lib.optionalAttrs (!wireplumberUsesConf) {
    "wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua".text = wireplumberLuaRule;
  };

  systemd.user.services.camera-relay = {
    description = "Camera Relay (on-demand libcamera to v4l2loopback)";
    after = [ "pipewire.service" "wireplumber.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${cameraRelay}/bin/camera-relay start --on-demand";
      ExecStop = "${cameraRelay}/bin/camera-relay stop";
      Restart = "on-failure";
      RestartSec = 5;
    };
    environment = libcameraEnv;
  };

  systemd.user.services.pipewire.environment = libcameraEnv;
  systemd.user.services.wireplumber.environment = libcameraEnv;
}
