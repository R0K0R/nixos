# Galaxy Book4 Pro 360 — IPU6 + libcamera (webcam-fix-libcamera).
# Ports upstream install.sh + patterns from nixos/webcam-fix-book5.nix.
# https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes

{ inputs, config, lib, pkgs, ... }:

let
  fixes = inputs.feat-samsung-galaxybook.fixes;
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

  /*
    ov02c10 fails to probe entirely on this board: dmesg shows
    "error -EINVAL: external clock 26000000 is not supported" / "probe with
    driver ov02c10 failed with error -22". The in-tree driver only accepts
    19.2 MHz; this board's IPU6 clocks the sensor at 26 MHz. Without a
    successful probe there's no v4l2 subdevice at all, so libcamera's Simple
    pipeline handler reports "No sensor found for /dev/media0" and
    camera-relay's gstreamer pipeline has nothing real to capture (produces a
    synthetic black frame instead of erroring). Same fix as ov02c10-26mhz-fix's
    DKMS module — patched source accepts both 19.2 MHz and 26 MHz. Out-of-tree
    modules in extra/ take priority over the in-tree kernel/ one in depmod's
    search order, same mechanism the DKMS variant relies on via /updates.
  */
  ov02c10Fix = pkgs.stdenvNoCC.mkDerivation {
    pname = "ov02c10-26mhz-fix";
    version = "1.0-${kernel.modDirVersion}";
    src = "${fixes}/ov02c10-26mhz-fix";
    nativeBuildInputs = [ kernel.dev cc pkgs.gnumake pkgs.perl ]
      ++ lib.optionals kernelUsesClang [ pkgs.llvmPackages.lld ];
    buildPhase = ''
      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
        M=$PWD modules ${clangMakeFlags} ${gccMakeFlags}
    '';
    installPhase = ''
      install -Dm644 ov02c10.ko $out/lib/modules/${kernel.modDirVersion}/extra/ov02c10.ko
    '';
    meta = with lib; {
      description = "ov02c10: accept 26 MHz external clock in addition to 19.2 MHz";
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

  /*
    Where gst-launch finds its plugins. nixpkgs wraps gst-launch-1.0 to build
    GST_PLUGIN_SYSTEM_PATH_1_0 from $NIX_PROFILES/lib/gstreamer-1.0 -- and a
    systemd --user unit has no NIX_PROFILES, so inside camera-relay.service the
    pipeline failed to parse with `no element "queue"` (coreelements lives in
    gstreamer's own out/lib/gstreamer-1.0; nothing on the unit's PATH implies
    it). The journal shows the consequence: from the first boot with this
    service (2026-07-05) to 2026-09-16, 650 pipeline starts and not one lived
    past two seconds. camera-relay-monitor papers over a dead pipeline with
    synthetic black frames, so nothing ever said so.

    GST_REGISTRY_1_0 goes with it. GStreamer keeps ONE registry cache per user
    and rebuilds it whenever the plugin-path set differs from the last run, so
    a relay with this plugin set and session apps without it would rebuild each
    other's cache on every start. A private registry file costs nothing and
    ends that.

    Set explicitly, and ONLY on the relay wrapper: putting it in libcameraEnv
    would push this tuned plugin set into every GStreamer process in the
    session via environment.sessionVariables, which is a wider change than the
    relay needs.
  */
  gstPluginPath = lib.makeSearchPath "lib/gstreamer-1.0" (
    # EXPLICIT `out`. gstreamer declares outputs = [ "bin" "out" "dev" "debug" ],
    # bin first, so a bare "${gstreamer}" is the bin output -- which has no
    # lib/gstreamer-1.0 at all. coreelements (queue, identity, fakesink) lives
    # in out. With the bare form the monitor's gst-launch still failed with
    # `no element "queue"` while videoconvert and libcamerasrc resolved,
    # because only the first path component was wrong. Measured 2026-09-16.
    map (lib.getOutput "out") (
      (with pkgs.gst_all_1; [ gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad ]) ++ [ pkgs.libcamera ]
    )
  );

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
        --set LIBCAMERA_IPA_PROXY_PATH ${pkgs.libcamera}/libexec/libcamera \
        --set LIBCAMERA_IPA_CONFIG_PATH ${pkgs.libcamera}/share/libcamera/ipa \
        --prefix GST_PLUGIN_PATH : ${lib.makeSearchPath "lib/gstreamer-1.0" [ pkgs.libcamera ]} \
        --set GST_PLUGIN_SYSTEM_PATH_1_0 ${gstPluginPath} \
        --run 'export GST_REGISTRY_1_0="''${XDG_CACHE_HOME:-$HOME/.cache}/camera-relay/gst-registry.bin"; mkdir -p "$(dirname "$GST_REGISTRY_1_0")"' \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.libcamera ]}
    '';
  };

  libcameraEnv = {
    LIBCAMERA_IPA_MODULE_PATH = "${pkgs.libcamera}/lib/libcamera/ipa";
    /*
      Where the IPA proxy workers live. Needed whenever an IPA module runs
      ISOLATED -- which libcamera does for any module whose signature fails to
      verify -- and libcamera cannot find them on its own here:

        src/libcamera/source_paths.cpp isLibcameraInstalled() answers "not
        installed" if libcamera.so carries a DT_RUNPATH. Every Nix library
        does, so on Nix it is ALWAYS "not installed", and resolvePath() then
        derives a build-tree root from dirname(libcamera.so)/../../ -- which is
        /nix/store -- and looks for /nix/store/src/libcamera/proxy/worker.
        The compiled-in IPA_PROXY_DIR (libexec/libcamera, where the workers
        really are) is never consulted on that branch.

      With the env var set, resolvePath() checks it FIRST, before either
      heuristic. This is belt-and-braces: the primary fix is keeping libcamera
      input-addressed (tuning/heavy.nix skip) so the signatures verify and the
      IPA runs in-process, but with this in place a future signature break
      degrades to isolated-but-working instead of "software ISP disabled" and
      black frames.

      UPSTREAM TODO (nixpkgs): the RUNPATH heuristic is wrong for any distro
      that keeps RUNPATH on installed libraries. Either patch
      isLibcameraInstalled() or set LIBCAMERA_IPA_PROXY_PATH in a wrapper.
    */
    LIBCAMERA_IPA_PROXY_PATH = "${pkgs.libcamera}/libexec/libcamera";
    # Same heuristic, same failure, for the IPA tuning files: without this the
    # isolated worker starts and then fails init with "Configuration file
    # 'ov02c10.yaml' not found ... falling back to ''". ov02c10.yaml IS shipped,
    # under share/libcamera/ipa/simple/.
    LIBCAMERA_IPA_CONFIG_PATH = "${pkgs.libcamera}/share/libcamera/ipa";
    /*
      That is ALL the session gets -- deliberately. There is one camera path:
      libcamera -> camera-relay -> v4l2loopback ("Camera Relay"), and apps use
      the V4L2 device. The relay is the only thing that opens the sensor.

      This used to also export GST_PLUGIN_PATH/LD_LIBRARY_PATH for libcamera,
      handing every GStreamer app `libcamerasrc` -- direct sensor access that
      bypasses the relay and fights it for the camera (libcamera allows one
      owner). kamoso's autoplugger preferred it and rendered a transparent
      preview (ABGR with a garbage alpha), which is what the old
      `GST_PLUGIN_FEATURE_RANK = "libcamerasrc:0"` hack papered over. With
      libcamerasrc no longer visible to the session, that problem cannot
      occur, so the hack is gone too.

      The three IPA variables above stay because they are inert unless
      something links libcamera directly -- i.e. the relay and the `cam`
      diagnostic tool -- and without them `cam` fails the isolated-IPA lookup.
      The relay's own wrapper sets its GStreamer paths itself.
    */
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

  /*
    The second camera path, removed. WirePlumber's libcamera monitor exposes
    the sensor as its own PipeWire source ("Built-in Front Camera",
    libcamera_input.__SB_.PC00.LNK0) beside the relay's "Camera Relay (V4L2)".
    Apps that take the first source rather than the default picked it, and it
    competed with the relay for the sensor. Disabled at the monitor, so the node
    is never created -- not merely hidden.
  */
  wireplumberNoLibcameraConf = ''
    wireplumber.profiles = {
      main = {
        monitor.libcamera = disabled
      }
    }
  '';
  wireplumberNoLibcameraLua = ''
    libcamera_monitor.enabled = false
  '';
  wireplumberUsesConf = lib.versionAtLeast (pkgs.wireplumber.version or "0.5") "0.5";
in
lib.mkIf config.my.samsung-galaxybook.enable {
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
          # The upstream tuning file's Ccm block (boost R/B 1.05x, cut G to 0.92x)
          # was calibrated against someone else's unit that ran green; on this
          # unit it overshoots into magenta instead. Confirmed by testing with
          # LIBCAMERA_IPA_CONFIG_PATH pointed at a copy with the Ccm block
          # removed — tint fixed. Drop just the Ccm algorithm entry.
          sed -i '/- Ccm:/,/-0.01, -0.02,  1.05 \]/d' \
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
    ov02c10Fix
    kernelPackages.v4l2loopback
  ];

  environment.systemPackages = [
    cameraRelay
    pkgs.libcamera
    pkgs.v4l-utils
  ];

  environment.sessionVariables = libcameraEnv;

  # Keyed off the primary account rather than a literal: `users.users.<n>.X`
  # DECLARES the user, so a literal name here creates a stray half-defined
  # account on any host where that person does not exist.
  users.users.${config.my.internal.primaryUser}.extraGroups = [ "kvm" ];

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
      # width/height/max_*: without a fixed format declared at module load,
      # the loopback device has no known capability until the on-demand relay
      # actually starts producing frames. PipeWire enumerates a device's
      # formats once when it discovers the node; if that happens while the
      # relay is idle, it caches an empty format list and every future
      # consumer (cheese, any PipeWire-based app) fails permanently with
      # "no more input formats", even after the relay starts. Declaring a
      # fixed format up front matches what camera-relay-monitor always
      # produces (1920x1080) regardless of on-demand state.
      options v4l2loopback devices=1 exclusive_caps=0 card_label="Camera Relay" width=1920 height=1080 max_width=1920 max_height=1080
    '';
  }
  // lib.optionalAttrs wireplumberUsesConf {
    "wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf".text = wireplumberConfRule;
    "wireplumber/wireplumber.conf.d/51-no-libcamera-monitor.conf".text = wireplumberNoLibcameraConf;
  }
  // lib.optionalAttrs (!wireplumberUsesConf) {
    "wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua".text = wireplumberLuaRule;
    "wireplumber/main.lua.d/52-no-libcamera-monitor.lua".text = wireplumberNoLibcameraLua;
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

}
