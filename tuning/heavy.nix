/*
  my.tuning.heavy -- mold + ccache across the tuned host set.

  Scope is the runtime classifier, not a hand-picked list: the same set
  overlays/ca.nix marks content-addressed. Those derivations already differ
  from upstream because of the march, so they never substituted from
  cache.nixos.org and adding a linker and a compiler cache costs no
  substitutability at all. The build platform is left alone.

  Three deliberate holes, each opt-in rather than global:

  - `mold.exclude` keeps the normal linker for a name and everything under it.
    The kernel is there because it drives its own link with $(LD) instead of
    going through the compiler driver, so -fuse-ld=mold is inert at best there.
    ccache still applies.
  - `noDebugInfo.packages` turns separateDebugInfo off. That removes debug
    symbols, so it is worth it only where the DWARF dwarfs the output:
    webkitgtk measured 125 MB of library against 460 MB of debug info, and its
    setup hook is what injects the -ggdb that produces it, so the cost is paid
    at compile time too.
  - `scopes` and `extras` reach what the classifier's names cannot: members of
    package sets (qt6 modules, kdePackages) and attributes whose name differs
    from the derivation's or that take a non-default stdenv argument.

  ccache's own configuration (cache dir, sizes, L2 peers) lives in
  features/ccache. Only `wrapperConfig` crosses over, and it carries no
  remote-storage setting on purpose: env is ccache's highest-precedence config
  source, so L2 there would be baked into every derivation hash instead of
  staying a runtime lever.
*/
{ config, inputs, lib, hostName, ... }:

let
  cfg = config.my.tuning.heavy;
  hostRuntimeClassifier = import ./host-runtime-classifier.nix {
    inherit inputs;
    host = hostName;
    system = "x86_64-linux";
  };
in
{
  options.my.tuning.heavy = {
    enable = lib.mkEnableOption "mold + ccache for the tuned host package set";

    mold = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Link the tuned host set with mold instead of ld.bfd.";
      };

      exclude = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          # quickshell: linked with mold, the Hyprland IPC singleton never
          # populates focusedWorkspace/focusedMonitor -- both read back as
          # `undefined` in QML while the workspaces list loads fine, so any
          # workspace widget loses its active highlight. Identical source,
          # version and tuning link correctly under ld.bfd, so this is the
          # linker, not the package. Bisected 2026-09-09 against 0.3.1.
          "quickshell"

          # links with $(LD) itself rather than through the compiler driver
          "linux"
          "linuxPackages"
          "linuxPackages_latest"
          "linuxKernel"

          # nss links bin/hw-support against static archives in a
          # --start-group, with libnss3.so only AFTER the group. libcerthi.a's
          # certvfypkix.o references internal PKIX_* symbols, and no pkix
          # archive is on that line -- ld.bfd never extracts that member, mold
          # does, and the link fails on undefined symbols (2026-09-08).
          "nss"
        ];
        description = ''
          Names kept on the normal linker. They still get ccache. Expect to add
          to this: a tree-wide linker swap finds every build that depends on
          ld.bfd's exact archive-extraction behaviour, and each one surfaces as
          undefined symbols at link time.
        '';
      };
    };

    skip = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # The stdenv's own closure. Treating these is a cycle, not a choice:
        # a stdenv derived from the stdenv needs the compiler it is rebuilding.
        "gcc" "binutils" "glibc" "libgcc" "glibc-locales" "linux-headers"
        "clang" "libcxx" "llvm" "compiler-rt"
        "bash" "coreutils" "findutils" "diffutils" "gnused" "gnugrep" "gawk"
        "gnutar" "gzip" "bzip2" "xz" "patch" "file" "ed" "gnumake" "patchelf"

        # zsh bakes its own $out into the binary as the default module_path
        # (lib/zsh/$VERSION, where zle.so and friends live). Content-addressed,
        # the rewrite left that string pointing at the pre-rewrite path, so the
        # installed zsh looked for its modules in a store path that does not
        # exist: every zmodload failed and zle, terminfo, parameter and compinit
        # were all dead. Verified 2026-09-13 -- `zsh -f -c 'print $module_path'`
        # named a path `nix path-info` could not even resolve.
        "zsh"

        # libcamera SIGNS its IPA modules (lib/libcamera/ipa/*.so.sign) in
        # postFixup, after strip and RPATH fixup -- and Nix's content-addressed
        # self-reference rewrite runs after THAT. ipa_soft_simple.so carries its
        # own $out in its RUNPATH, so the rewrite changed its bytes and the
        # signature stopped verifying. An unsigned IPA is run in isolation,
        # which needs the proxy worker, which libcamera then cannot find
        # (see features/samsung-galaxybook/webcam.nix), so the software ISP
        # never came up and every app got raw Bayer -- black frames through
        # camera-relay. The untuned, input-addressed build of the same version
        # verifies fine. Same hazard class as zsh above: anything that signs or
        # checksums its own self-referencing output cannot be content-addressed.
        # Verified 2026-09-16 with `LIBCAMERA_LOG_LEVELS=IPAManager:DEBUG cam -l`.
        #
        # NOT LISTED YET, deliberately. Adding "libcamera" is the principled fix
        # (in-process IPA, valid signatures) but tuned pipewire depends on tuned
        # libcamera, and pipewire is under most of the desktop: the dry-run was
        # 850 derivations. features/samsung-galaxybook/webcam.nix instead sets
        # LIBCAMERA_IPA_PROXY_PATH so the isolated IPA finds its worker, which
        # makes the camera work with no package rebuild. Uncomment the line
        # below to ride the correct fix along with the next large rebuild.
        # "libcamera"
      ];
      description = "Names left completely untouched: no mold, no ccache. The stdenv's own closure has to be here.";
    };

    scopes = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      default = [
        { scope = "qt6"; }
        { scope = "kdePackages"; }
      ];
      description = "Package sets whose members are not top-level attributes; their whole scope gets the tuned stdenv.";
    };

    extras = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      default = [
        { attr = "webkitgtk_4_1"; stdenvArg = "clangStdenv"; }
        { attr = "webkitgtk_6_0"; stdenvArg = "clangStdenv"; }
        { attr = "hyprland"; stdenvArg = "gcc16Stdenv"; }
        # Links libhyprlang/libhyprutils, which the hyprland override above
        # builds with gcc 16. Left on the default gcc 15 stdenv it resolves a
        # libstdc++ without GLIBCXX_3.4.35/36 and dies at startup.
        { attr = "xdg-desktop-portal-hyprland"; stdenvArg = "gcc16Stdenv"; }
      ];
      description = "Attributes the classifier's names miss, or that take a non-default stdenv argument.";
    };

    noDebugInfo.packages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "webkitgtk_4_1"
        "webkitgtk_6_0"
      ];
      description = "Top-level packages built with separateDebugInfo = false. Opt-in; missing names are skipped.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = lib.mkBefore [
      (import ./overlays/heavy.nix {
        inherit lib;
        mold = cfg.mold.enable;
        moldExclude = cfg.mold.exclude;
        inherit (cfg) skip;
        names = hostRuntimeClassifier.runtimeNames;
        inherit (cfg) scopes extras;
        noDebugInfoNames = cfg.noDebugInfo.packages;
        ccache = {
          inherit (config.my.ccache) enable;
          normalize = config.my.ccache.crossDerivation.enable;
          extraConfig = config.my.ccache.wrapperConfig;
        };
      })
    ];
  };
}
