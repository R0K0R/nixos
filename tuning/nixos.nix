{ config, inputs, lib, pkgs, hostName, tuningEnabledRaw, tuningMarchRaw, ... }:

let
  cfg = config.my.tuning;

  /*
    Computed once and shared between the o3 and gentoo-lto overlays -- each
    independently importing/recomputing this (a genericClosure walk across ~400
    packages) roughly doubles eval time for no benefit, since both need the
    identical result.
  */
  # o3/lto without march: tune the one native set (overlays/native-target.nix).
  native = cfg.march == null;

  # Native mode only: the candidates a build tool links, left untuned there.
  nativeBuildTools = import ./native-build-tools.nix { inherit inputs lib; };

  /*
    Native mode only: this host's package set as it would be with o3/lto off --
    the alias target for everything that is not host-runtime. Built the way
    nixos/modules/misc/nixpkgs.nix builds `pkgs` for a native host (same
    nixpkgs, nixpkgs.config, nixpkgs.overlays, localSystem = hostPlatform), so
    its derivations ARE the all-off variant's, plus a config marker that the
    tuning overlays read to stand down (overlays/native-target.nix). nixpkgs'
    config is freeform, and no package reads that key, so the marker moves no
    derivation.

    inputs.nixpkgs-upstream rather than `pkgs.path`: native means march = null,
    which flake.nix forkWanted maps to upstream, and reading `pkgs` here would
    tie this to the fixpoint it is an input of.
  */
  nativeBaseline = import inputs.nixpkgs-upstream {
    localSystem = config.nixpkgs.hostPlatform;
    config = config.nixpkgs.config // { tuningNativeBaseline = true; };
    overlays = config.nixpkgs.overlays;
  };

  candidateDefaults = import ./candidates.nix;
  forced = cfg.o3.force ++ cfg.lto.force;
  /*
    What the tuning overlays ask. With no forced names it IS the shared
    classifier; with some, those names also count as host-runtime -- so
    upstream-tools does not substitute them from upstream either. heavy.nix
    and ca.nix keep the plain one (module argument below).
  */
  overlayClassifier =
    if forced == [ ] then
      hostRuntimeClassifier
    else
      hostRuntimeClassifier
      // {
        isHostRuntime = n: builtins.elem n forced || hostRuntimeClassifier.isHostRuntime n;
        runtimeNames = lib.unique (hostRuntimeClassifier.runtimeNames ++ forced);
      };
  hostRuntimeClassifier = import ./host-runtime-classifier.nix {
    inherit inputs;
    host = hostName;
    system = "x86_64-linux";
  };
in
{
  options.my.tuning = {
    enable = lib.mkEnableOption ''
      this machine-bound tuning backend, and with it the patched nixpkgs fork.

      OFF (the default) is not merely "no -march". It selects a different
      nixpkgs INPUT for this host -- plain upstream, so the entire package set
      substitutes from cache.nixos.org. Turning march off while staying on the
      fork would NOT achieve that (which is why march = null now leaves the fork
      too, below): the fork patches
      pkgs/build-support/cc-wrapper/setup-hook.sh, whose bytes are a build input
      to cc-wrapper, so stdenv's hash moves and every package rebuilds no matter
      what the tuning switches say. Measured: reverting that one file alone
      changes hello.drvPath at plain `import <fork> {}`, with no march, no
      gcc.arch and no overlays. Two more such files (qt-5 and qt-6
      qtbase-setup-hook.sh) do the same for the whole Qt package set.

      The fork itself is selected only when `march` is also set (flake.nix
      forkWanted): march is the one lever that needs it, and every other lever
      that would need it asserts march. `enable = true` with `march = null`
      therefore runs on plain upstream nixpkgs and keeps the levers that do not
      care (o3 and lto, in their native mode; heavy, refreshTool). Content addressing is not a tuning lever at all
      any more: it is features/nix/ca-derivations.

      Because the choice is an input rather than an option value, it is read out
      of the host file by raw import in flake.nix -- see the note there. It must
      therefore be a LITERAL true/false in hosts/<name>/default.nix (and march a
      literal string or null): no mkIf, no mkMerge, no reference to `config`. The assertion below catches any
      divergence between what flake.nix read and what the module system
      evaluated, so an ignored definition can never pass silently.

      my.tuning.extraOverlays is deliberately NOT gated on this -- it describes
      the machine's hardware, not its toolchain -- and it keeps working on
      upstream nixpkgs because this swaps the input rather than setting
      nixpkgs.pkgs, which would have made overlays silently inert.
    '';

    march = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "meteorlake";
      description = ''
        GCC `-march` for this host's package set, or null for an untuned
        (plain upstream) build.

        Setting it declares buildPlatform WITHOUT gcc.arch so that it differs
        from hostPlatform, which is what makes this an IntraISACross
        build rather than a native one.

        That split is not tuning for its own sake -- it is what
        overlays/upstream-tools.nix keys off. Natively (host == build) there is
        only ONE package set, so that overlay's guard falls through and it
        aliases *everything* to upstream, silently deleting the arch/O3/LTO
        tuning entirely. With the split, pkgsBuildHost is plain x86_64 and
        byte-identical to upstream (so build tools substitute from
        cache.nixos.org), while pkgs stays tuned for anything that runs here.
      '';
    };

    intraISACross.enable = lib.mkEnableOption ''
      the generic IntraISACross and build-load fixes in
      overlays/intra-isa-cross.nix -- cross-build configure defects, test suites
      that fail under builder load, and the i686 escape hatch. Wanted by any
      tuned host; nothing in it is specific to one machine
    '';

    /*
      Independent of march. With it they tune the gcc.arch host splice; without
      it (march = null, plain upstream nixpkgs) they tune the one native set,
      minus anything a build tool links, with everything not host-runtime kept
      at its untuned derivation. See the NATIVE ISOLATION entry below.
    */
    o3.enable = lib.mkEnableOption "the -O3 overlay, applied to host-runtime packages only";
    lto.enable = lib.mkEnableOption "the Gentoo-style LTO overlay, applied to host-runtime packages only";

    /*
      Per-package levers. `candidates` is every package the lever may touch
      (the classifier then keeps the host-runtime ones), `exclude` takes names
      back out -- a package a lever breaks. `force` is internal: names tuned
      REGARDLESS of the classifier and never substituted from upstream, which
      is how a user's explicit my.tuning.packages.<lever> reaches their own
      package set (lib/user-tuning.nix); a host has no reason to set it.
    */
    o3.candidates = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = candidateDefaults.o3;
      defaultText = lib.literalExpression "(import ./tuning/candidates.nix).o3";
      description = "Packages the o3 lever may touch (top-level attribute names).";
    };
    o3.exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Names the o3 lever must not touch, whatever the candidates say.";
    };
    o3.force = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Names o3 tunes regardless of the classifier (a user's explicit list).";
    };
    lto.candidates = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = candidateDefaults.lto;
      defaultText = lib.literalExpression "(import ./tuning/candidates.nix).lto";
      description = "Packages the lto lever may touch. Names o3 may claim are skipped (one overrideAttrs per package).";
    };
    lto.exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Names the lto lever must not touch.";
    };
    lto.force = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Names lto tunes regardless of the classifier (a user's explicit list).";
    };

    upstreamTools.enable = lib.mkEnableOption ''
      substituting build-platform tools with byte-identical upstream builds, so
      they come from cache.nixos.org instead of being rebuilt
    '';

    qtPatches.enable = lib.mkEnableOption ''
      pkgs-config.nix: qtbase F16C/mysql patching and the yulee-sandbox test
      exclusions. Meteorlake-specific -- a differently-tuned host wants its own
    '';

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = "Where this flake lives on disk, baked into runtime-cache-refresh.";
    };

    /*
      The per-user half of the classifier's cache (docs/multiuser-design.md,
      "Every user feeds the classifier"): /var/lib/tuning-cache/<host>/users,
      where every user may write their own <user>.nix (sticky, like /tmp),
      and the tuning-refresh command that writes it. Independent of `enable`:
      evidence is about which packages run here, whoever tunes them.
      The system's own files (system-tier{1,2}.nix) and the switch of the
      flake's tuning-cache-<host> inputs to this directory are the admin's
      one-time migration, scripts/tuning-cache-migrate.sh.
    */
    userCache.enable = lib.mkEnableOption "the per-user tuning cache directory and tuning-refresh";

    extraOverlays = lib.mkOption {
      type = lib.types.listOf (lib.types.functionTo (lib.types.functionTo lib.types.attrs));
      default = [ ];
      description = ''
        Host-specific overlays: this machine's GPU, its fingerprint sensor, a
        compositor package set. Anything that is about the hardware rather than
        about the toolchain, and so cannot be shared.
      '';
    };
  };

  imports = [
    ./pkgs-config.nix
    ./runtime-cache-refresh.nix
    ./heavy.nix
    ./ca.nix
  ];

  config = lib.mkMerge [
    /*
      The ONE classifier instance, handed to heavy.nix and ca.nix as a module
      argument. Each used to import its own copy, and every copy builds a fresh
      nixpkgs (lookup.nix freshPkgs) and walks the Tier 3 closure again: three
      of each per evaluation, measured as part of a 73 s eval on 2026-10-08.
    */
    { _module.args = { inherit hostRuntimeClassifier; }; }

    /*
      extraOverlays applies UNCONDITIONALLY -- it is not tuning.

      It used to sit inside the march gate, which meant `march = null` also
      silently dropped this host's GPU driver trim and its niri package set:
      overlays that describe the machine's hardware and have nothing to do
      with the toolchain, exactly as this option's own description says. The
      niri one is the sharp edge -- it would vanish with no error and only
      surface later as a missing compositor.
    */
    { nixpkgs.overlays = cfg.extraOverlays; }

    (lib.mkIf cfg.userCache.enable {
      my.state.system.state.directories = [
        "/var/lib/tuning-cache" # classifier evidence per host and user; the flake inputs path: into it
      ];
      systemd.tmpfiles.rules = [
        "d /var/lib/tuning-cache 0755 root root -"
        "d /var/lib/tuning-cache/${hostName} 0755 root root -"
        "d /var/lib/tuning-cache/${hostName}/users 1777 root root -"
      ];
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "tuning-refresh" ''
          export PATH=${
            lib.makeBinPath [
              config.nix.package
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
              pkgs.gnused
              pkgs.jq
              pkgs.util-linux
              config.systemd.package
            ]
          }''${PATH:+:$PATH}
          SYSTEM_FLAKE=${lib.escapeShellArg cfg.flakePath}
          set -uo pipefail
          ${builtins.readFile ./runtime-cache/tuning-refresh.sh}
        '')
      ];
    })

    /*
      Everything from here to the assertions is the tuning backend proper, and
      exists only when this host opted in. With `enable = false` flake.nix has
      already handed the host plain upstream nixpkgs, so leaving any of it
      active would tune a package set that is meant to substitute wholesale.

      The assertions stay OUTSIDE this gate on purpose: `march = "meteorlake"`
      next to `enable = false` must produce an error naming the missing line,
      not a silently untuned machine that still looks configured.
    */
    (lib.mkIf cfg.enable (lib.mkMerge [

    /*
      march itself: the buildPlatform/hostPlatform split, and nothing else.
      Every tuning overlay below is now gated on its OWN switch rather than
      riding along with this one.
    */
    (lib.mkIf (cfg.march != null) {
      nixpkgs.buildPlatform = "x86_64-linux";

      nixpkgs.hostPlatform = lib.systems.elaborate {
        system = "x86_64-linux";
        gcc.arch = cfg.march;
      };
    })

    /*
      Overlay ORDER is preserved exactly as it was when these shared one list:
      o3, lto, then the IntraISACross pair, then extraOverlays at the default
      priority -- mkMerge concatenates same-priority definitions in the order
      written -- and upstream-tools last at mkOrder 1600, so it sees fork
      packages and aliases last.

      (extraOverlays is defined above rather than here purely so its comment
      can stand alone; same priority, and it is written after these, so it
      still lands after them. If that ever stops being true, upstream-tools'
      1600 is the only ordering that actually matters to correctness.)
    */
    /*
      o3 and lto take `native` so they work WITHOUT march: three levers, not
      one lever and two riders. With march they tune the gcc.arch host splice
      exactly as before (native = false is the old code path, so a march'd
      host's derivations do not move); without it they tune the one native set
      instead (overlays/native-target.nix). The native half of what the split
      used to guarantee -- build tools untuned and substitutable -- is the
      native-isolation entry below.
    */
    (lib.mkIf cfg.o3.enable {
      nixpkgs.overlays = [
        (import ./overlays/o3.nix {
          hostRuntimeClassifier = overlayClassifier;
          inherit native nativeBuildTools;
          inherit (cfg.o3) candidates exclude force;
        })
      ];
    })

    (lib.mkIf cfg.lto.enable {
      nixpkgs.overlays = [
        (import ./overlays/gentoo-lto.nix {
          hostRuntimeClassifier = overlayClassifier;
          inherit native nativeBuildTools;
          inherit (cfg.lto) candidates exclude force;
          # Only what o3 actually claims: nothing when o3 is off in this set.
          o3Names = lib.optionals cfg.o3.enable (cfg.o3.candidates ++ cfg.o3.force);
        })
      ];
    })

    (lib.mkIf cfg.intraISACross.enable {
      nixpkgs.overlays =
        [ (import ./overlays/perl-tk-stub.nix) ]
        ++ import ./overlays/intra-isa-cross.nix { inherit lib inputs; };
    })

    (lib.mkIf cfg.upstreamTools.enable {
      nixpkgs.overlays = lib.mkOrder 1600 [
        (import ./overlays/upstream-tools.nix { inherit lib inputs; hostRuntimeClassifier = overlayClassifier; })
      ];
    })

    /*
      NATIVE ISOLATION: part of the o3/lto levers themselves when march is
      null, not the upstreamTools lever and not something it auto-enables.

      Without the split, pkgsBuildHost IS pkgs, so a tuned openssl would also
      be the one every curl/git/python3 build tool links: build tools change,
      stop substituting, and take their consumers with them. Two halves keep
      that from happening: o3/lto skip every candidate a build tool links
      (native-build-tools.nix, passed to them above), and this overlay points
      every attribute the classifier does not call host-runtime back at
      nativeBaseline -- the derivation it is with o3/lto off -- so only what
      runs here is rebuilt. Full reasoning, measurements, and where it is
      weaker than the split, in overlays/upstream-tools.nix (NATIVE MODE).

      Why not the alternatives:

        a generic "x86-64" hostPlatform, to manufacture a split: it IS a
          split, i.e. IntraISACross -- it needs the fork (the cc-wrapper
          setup-hook acts under NIX_IS_INTRA_ISA_CROSS) and rebuilds the
          whole host set through it, which is march with a no-op -march.
          "lto without march" would then not be on upstream nixpkgs at all.
        the overlays with only the classifier as filter: 2913 derivations
          with new outputs for lto alone on galaxybook4-pro360, python3, perl,
          meson, clang and a full gcc among them (native-build-tools.nix).
        a tuned second fixpoint whose host-runtime names are copied in: its
          host-runtime packages would be built with tuned build tools (cmake
          over a tuned curl), so the build tools change anyway.

      Same mkOrder 1600 as upstreamTools, for the same reason: last, so it
      sees every other overlay's result. The two can never both be on (the
      upstreamTools lever asserts march, this one requires march = null).
    */
    (lib.mkIf (native && (cfg.o3.enable || cfg.lto.enable)) {
      nixpkgs.overlays = lib.mkOrder 1600 [
        (import ./overlays/upstream-tools.nix {
          inherit lib inputs native nativeBaseline;
          hostRuntimeClassifier = overlayClassifier;
        })
      ];
    })

    ]))

    /*
      The one thing that cannot be expressed as an ordinary dependency: whether
      flake.nix's raw read of this option agrees with what the module system
      actually evaluated.

      They diverge if my.tuning.enable is ever set from somewhere the raw import
      cannot see -- another module, a property list, an mkForce in a profile. The
      failure that produces is the worst available: flake.nix picks upstream
      nixpkgs while every module here behaves as though the fork were in place
      (or the reverse), and nothing else in the system would notice. Comparing
      the two is the only place that mismatch is visible.
    */
    {
      assertions = [
        {
          assertion = cfg.enable == tuningEnabledRaw && cfg.march == tuningMarchRaw;
          message = ''
            my.tuning.enable/march evaluated to ${lib.boolToString cfg.enable}/${
              toString cfg.march
            }, but flake.nix read ${lib.boolToString tuningEnabledRaw}/${
              toString tuningMarchRaw
            } from hosts/${hostName}/default.nix, and has already selected the ${
              if tuningEnabledRaw && tuningMarchRaw != null then "patched fork" else "plain upstream"
            } nixpkgs on that basis.

            Set my.tuning.enable and my.tuning.march as literals in
            hosts/${hostName}/default.nix. They cannot be defined from another module or
            wrapped in mkIf/mkMerge: the nixpkgs input is chosen before the module system
            exists.
          '';
        }
      ];
    }

    /*
      Which levers still need march, and why o3/lto no longer do.

      o3 and lto used to be asserted here too: their overlays skipped every
      package set without gcc.arch, so without march they were silently inert.
      They now carry a native mode (overlays/native-target.nix and the NATIVE
      ISOLATION entry above), so they are levers in their own right.

      What remains genuinely needs the split. upstreamTools (the lever) is
      worse than inert without it: its host/build discrimination collapses
      and it aliases EVERYTHING to upstream -- silently deleting whatever
      tuning is enabled. Its native counterpart is the NATIVE ISOLATION entry,
      which o3/lto bring along themselves rather than by enabling this
      lever. intraISACross and qtPatches are fixes for the split and for the
      fork's meteorlake qtbase.

      So: assert, never auto-enable, per features/_meta's rule. The message
      names the exact line to add.
    */
    {
      assertions =
        /*
          Everything here hangs off `enable`, because with it off the host is on
          plain upstream nixpkgs and none of these can do what they claim.
          march is called out separately from the overlays: it is the one that
          silently produces a WORKING but fully-rebuilt system (an IntraISACross
          split against an unpatched tree), which is the outcome hardest to
          notice and most expensive to sit through.
        */
        [
          {
            assertion = cfg.march == null || cfg.enable;
            message =
              "my.tuning.march is set to ${toString cfg.march} but my.tuning.enable is false. "
              + "flake.nix has given this host plain upstream nixpkgs, so the IntraISACross "
              + "split would rebuild the entire package set against an unpatched tree instead "
              + "of substituting it from cache.nixos.org. Add my.tuning.enable = true;";
          }
          {
            assertion = !cfg.qtPatches.enable || cfg.enable;
            message =
              "my.tuning.qtPatches.enable requires my.tuning.enable (its overlays and "
              + "nixpkgs.config entries only make sense against the patched fork)";
          }
        ]
        ++ map
          (o: {
            assertion = !o.enabled || cfg.march != null;
            message = "my.tuning.${o.name}.enable requires my.tuning.march to be set (it is null; ${o.why})";
          })
          [
            {
              name = "upstreamTools";
              enabled = cfg.upstreamTools.enable;
              why = "without the split it aliases everything to upstream, deleting all tuning";
            }
            {
              name = "qtPatches";
              enabled = cfg.qtPatches.enable;
              why = "it patches the fork's meteorlake qtbase, and without march flake.nix selects plain upstream nixpkgs";
            }
            {
              name = "intraISACross";
              enabled = cfg.intraISACross.enable;
              why = "its fixes only apply to cross builds, and there is no split without march";
            }
          ];
    }
  ];
}
