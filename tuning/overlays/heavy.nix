/*
  Per-package build-time treatments for the HEAVY set: ccache, mold, and no
  debug info -- composed on one stdenv so they cannot fight over `.override`.

  Measured 2026-09-07 before any of this was written (see the ccache memory /
  plan for the runs):
    - ccache pays back only on rebuilds of the SAME derivation inputs
      (interrupted build, resume on the other builder, post-GC, --check); it
      cannot bridge a dependency bump under Nix, and the symlink trick that
      could was rejected as not safe enough. Hence an explicit list, not global.
    - webkitgtk links ONE ~585 MB object with ld.bfd (125 MB .so + 460 MB DWARF
      from separateDebugInfo); mold and dropping -ggdb attack that directly,
      and ccache never caches links -- the three are complementary.

  ORDERING. This overlay is registered with lib.mkBefore so it runs BEFORE
  o3.nix / gentoo-lto.nix. Those use overrideAttrs, which leaves a `.override`
  that no longer exposes the original `stdenv` argument (verified: curl,
  protobuf, abseil-cpp, boost show 1-2 override args under the tuning
  overlays). Running first, `prev.<name>` is the pristine callPackage result,
  the stdenv swap works, and the tuning flags layer on top unchanged.

  Same guards as the other tuning overlays: nixpkgs re-runs the overlay list
  for every bootstrap stage, and only the march'd HOST set is meant to be
  touched (build-platform packages substitute from cache.nixos.org).
*/
{ lib, ccache, mold, noDebugInfo, entries }:

final: prev:
if
  builtins.match ".*bootstrap.*" (prev.stdenv.name or "") != null
  || ((prev.stdenv.hostPlatform.gcc or { }).arch or "") == ""
then
  { }
else
  let
    # base stdenv -> [mold-linked] -> [no separate debug info] -> [ccache-wrapped]
    mkStdenv =
      { useMold, noDbg }:
      base:
      let
        # MOLD FIRST. useMoldLinker calls `stdenv.cc.override { bintools = ..; }`;
        # after ccache has wrapped the stdenv, `.cc.override` is ccacheWrapper's
        # own makeOverridable ({ extraConfig, cc }) and rejects `bintools`
        # (verified: "called with unexpected argument 'bintools'"). The other
        # way round composes: ccache's links wrap the mold-equipped cc, and the
        # -fuse-ld=mold that useMoldLinker adds via mkDerivationFromStdenv is
        # an accumulated stdenv.override arg, preserved through overrideCC.
        withMold = if useMold && mold then prev.stdenvAdapters.useMoldLinker base else base;
        # separateDebugInfo off at the stdenv, not per package: that is the
        # only way to reach scope members (qt6 modules, kdePackages) and it
        # also removes the -ggdb that separate-debug-info.sh injects into
        # every TU. extendMkDerivationArgs applies it as an overrideAttrs on
        # top, so it wins over a package's own `separateDebugInfo = true`.
        withDbg =
          if noDbg then prev.stdenvAdapters.addAttrsToDerivation { separateDebugInfo = false; } withMold else withMold;
        # Mirrors nixpkgs' ccacheStdenv but with OUR extraConfig: only
        # CCACHE_DIR and the static knobs. Deliberately NO remote-storage env
        # var -- env is ccache's highest-precedence source and would bake the
        # L2 choice into every derivation hash. L2 lives in the builder's
        # $CCACHE_DIR/ccache.conf, editable at runtime (features/ccache).
        #
        # Built from ccache.links directly rather than via `ccacheWrapper`:
        # that one is makeOverridable over { extraConfig, cc } and REPLACES the
        # cc-wrapper's `.override`, so anything downstream that does
        # `stdenv.cc.override { bintools = ..; }` -- useMoldLinker, and
        # packages like hyprland that apply it themselves -- breaks. This way
        # the result is a plain cc-wrapper with its full override surface.
        links = prev.buildPackages.ccache.links {
          extraConfig = ccache.extraConfig;
          unwrappedCC = withDbg.cc.cc;
        };
        ccacheCC = withDbg.cc.override {
          # cc-wrapper takes `version` from the cc it wraps, so a plain
          # ccache-links makes stdenv.cc.version read "4.13.6" (measured on
          # glib) and every `versionAtLeast stdenv.cc.version` gate in
          # nixpkgs -- useMoldLinker's own gcc>=12 check included -- goes
          # wrong. Report the real compiler's version instead.
          cc = links.overrideAttrs (_: { version = withDbg.cc.cc.version; });
        };
      in
      if ccache.enable then prev.overrideCC withDbg ccacheCC else withDbg;

    # Only swap through an argument the package actually declares. abseil-cpp
    # takes no `stdenv` at all and `.override { stdenv = ...; }` throws
    # "called with unexpected argument"; a wrong guess must degrade to
    # "untouched", never to an eval error in the middle of the system closure.
    # lib.functionArgs copes with both shapes of `override` (makeOverridable's
    # functor attrset, or a bare lambda) where `.__functionArgs` does not.
    takes = pkg: arg: lib.isAttrs pkg && pkg ? override && (lib.functionArgs pkg.override) ? ${arg};
    canSwap = pkg: arg: takes pkg arg || takes pkg "callPackage";
    # opts = { useMold, noDbg }, as mkStdenv takes them
    optsOf = e: {
      useMold = e.mold or true;
      noDbg = noDebugInfo && (e.noDebugInfo or true);
    };
    swapIn =
      pkg: arg: opts:
      let
        tuned = mkStdenv opts prev.${arg};
        # Version shims like protobuf_35 = callPackage ./35.nix { } expose
        # only `callPackage` to override; thread the stdenv through it into
        # the generic below, but only if that generic actually takes it.
        viaCallPackage =
          fn: a:
          let
            f = if lib.isFunction fn then fn else import fn;
          in
          prev.callPackage f (if (lib.functionArgs f) ? ${arg} then a // { ${arg} = tuned; } else a);
      in
      if takes pkg arg then
        pkg.override { ${arg} = tuned; }
      else if takes pkg "callPackage" then
        pkg.override { callPackage = viaCallPackage; }
      else
        pkg;

    treatAttr =
      e:
      let
        arg = e.stdenvArg or "stdenv";
        opts = optsOf e;
        pkg = prev.${e.attr};
        # a boolean test, not `swapped != pkg`: derivations hold functions and
        # attrset comparison over them is an eval error
        applicable = if e ? via then takes pkg e.via && pkg ? ${e.via} && canSwap pkg.${e.via} arg else canSwap pkg arg;
      in
      if !applicable then
        pkg
      else if e ? via then
        # wrapper packages: the compiled thing is behind a passthru
        # (libreoffice-qt-stable.unwrapped); swap the stdenv there and
        # hand the wrapper the result.
        pkg.override { ${e.via} = swapIn pkg.${e.via} arg opts; }
      else
        swapIn pkg arg opts;

    # Scopes. Without `members`: override the scope's `stdenv`, which the
    # module builders (qt6, kdePackages) take from the scope, so one change
    # covers every member (qtwebengine included). With `members`: only those,
    # for scopes where touching the shared stdenv would reach too far
    # (llvmPackages -- its stdenv IS clangStdenv's ancestry). noDebugInfo
    # rides along inside the stdenv, so it reaches scope members too.
    treatScope =
      e:
      # Whole scope, and the scope itself takes `stdenv` (qt6 is `callPackage
      # ../qt-6 { }` and hands every module that stdenv EXPLICITLY, so a scope
      # member added by overrideScope would lose to it): override at the top.
      if !(e ? members) && takes prev.${e.scope} "stdenv" then
        prev.${e.scope}.override { stdenv = mkStdenv (optsOf e) prev.stdenv; }
      else
      prev.${e.scope}.overrideScope (
        _: sp:
        if e ? members then
          # only the named members, each through its own `stdenv` arg
          builtins.listToAttrs (
            map (m: {
              name = m;
              value = swapIn sp.${m} "stdenv" (optsOf e);
            }) (builtins.filter (m: sp ? ${m}) e.members)
          )
        else
          # scopes without a `stdenv` member (kdePackages) resolve it from pkgs
          # via callPackage's fallback; adding one to the scope overrides that.
          { stdenv = mkStdenv (optsOf e) (sp.stdenv or prev.stdenv); }
      );

    attrEntries = builtins.filter (e: e ? attr && prev ? ${e.attr}) entries;
    scopeEntries = builtins.filter (e: e ? scope && prev ? ${e.scope}) entries;
  in
  builtins.listToAttrs (map (e: { name = e.attr; value = treatAttr e; }) attrEntries)
  // builtins.listToAttrs (map (e: { name = e.scope; value = treatScope e; }) scopeEntries)
