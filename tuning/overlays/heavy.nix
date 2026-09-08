/*
  mold + ccache across the tuned host set.

  `skip` is not a preference, it is a correctness requirement: the classifier's
  names include the stdenv's own parts (gcc, binutils, glibc, bash, coreutils,
  ...). Rebuilding those with a stdenv derived from the stdenv is a cycle --
  `stdenv.cc.isGNU` forces `stdenv.cc.cc`, which is the very `gcc` being
  overridden (measured: infinite recursion at adapters.nix:343). They are also
  the packages ccache and mold would help least.

  SELECTION is the runtime classifier, the same set overlays/ca.nix marks
  content-addressed: every host-runtime name that is also a top-level
  attribute. Those derivations already differ from upstream (gccarch), so they
  never substituted from cache.nixos.org and a linker or compiler cache costs
  them no substitutability -- only the one rebuild the switch pays anyway. The
  build platform (~91% of the toplevel closure, measured) is outside the guard
  below and stays byte-identical to upstream.

  Selection by NAME rather than by swapping `stdenv` itself: a global stdenv
  override in an overlay is infinite recursion (measured, twice -- once via
  `builtins.attrNames prev`, once from the swap alone). `scopes` covers package
  sets whose members are not top-level attributes (qt6 modules, kdePackages);
  `extras` covers packages whose attribute name the classifier does not carry
  or that take a non-default stdenv argument.

  ORDERING. Registered with lib.mkBefore so it runs BEFORE o3.nix and
  gentoo-lto.nix. Those use overrideAttrs, which leaves a `.override` that no
  longer exposes the original `stdenv` argument (verified: curl, protobuf,
  abseil-cpp, boost show 1-2 override args under the tuning overlays). Running
  first, `prev.<name>` is the pristine callPackage result, the stdenv swap
  works, and the tuning flags layer on top unchanged.

  COMPOSITION, both halves verified by eval: base -> useMoldLinker -> ccache.

  MOLD FIRST. `useMoldLinker` does `stdenv.cc.override { bintools = ...; }`.
  nixpkgs' `ccacheWrapper` is makeOverridable over `{ extraConfig, cc }` and
  REPLACES the cc-wrapper's own `.override`, so after it there is no `bintools`
  argument left and the call dies with "unexpected argument 'bintools'". For
  the same reason the ccache cc is built from `ccache.links` plus a plain
  `cc.override { cc = links; }` instead of through `ccacheWrapper`: that keeps
  the full cc-wrapper override surface, which packages applying useMoldLinker
  themselves (hyprland) still need.

  The links carry the REAL compiler's version. A cc-wrapper takes `version`
  from the cc it wraps, so bare ccache-links makes `stdenv.cc.version` read
  "4.13.6" (measured on glib) and every `versionAtLeast stdenv.cc.version` gate
  in nixpkgs, useMoldLinker's own gcc >= 12 test included, takes the wrong
  branch.

  No CCACHE env beyond CCACHE_DIR and the static knobs: env is ccache's
  highest-precedence config source, so remote storage there would bake the L2
  topology into every derivation hash instead of leaving it a runtime lever in
  the builder's $CCACHE_DIR/ccache.conf (features/ccache).
*/
{
  lib,
  ccache,
  mold,
  names,
  extras,
  scopes,
  skip,
  moldExclude,
  noDebugInfoNames,
}:

final: prev:
if
  builtins.match ".*bootstrap.*" (prev.stdenv.name or "") != null
  || ((prev.stdenv.hostPlatform.gcc or { }).arch or "") == ""
then
  { }
else
  let
    mkStdenv =
      { useMold }:
      base:
      let
        withMold = if useMold && mold then prev.stdenvAdapters.useMoldLinker base else base;
        links = prev.buildPackages.ccache.links {
          extraConfig = ccache.extraConfig;
          unwrappedCC = withMold.cc.cc;
        };
        ccacheCC = withMold.cc.override {
          /*
            cc-wrapper names and versions itself after the cc it wraps, and
            ccache.links calls itself "ccache-links" at ccache's own version. So
            a ccache'd wrapper reads "…-ccache-links-wrapper-4.13.6" and loses
            BOTH the compiler's identity and its version. Two consequences,
            both measured:

            - every `versionAtLeast stdenv.cc.version` gate in nixpkgs compares
              against 4.13.6, useMoldLinker's own gcc >= 12 test included.
            - tuning/pkgs-config.nix skips its GCC-only
              -Wno-error=maybe-uninitialized for `*-clang-wrapper-*`. Renamed,
              the guard missed, clang got the flag, and its "unknown warning
              option" reply matches CMake's FAIL_REGEX -- failing EVERY
              check_compiler_flag despite exit 0. webkitgtk's configure died on
              "Failed to detect support for atomic variables".

            Fixed here rather than in the fork's ccache because THIS FLAKE does
            not use the fork's ccache: it is build-only, so upstream-tools.nix
            aliases it to the nixpkgs-upstream input to keep it substitutable.
            A fork patch to pkgs/by-name/cc/ccache is simply never evaluated.

            The name must END in the compiler for pkgs-config's glob to match.
          */
          cc = links.overrideAttrs (_: {
            version = withMold.cc.cc.version;
            pname = if withMold.cc.isClang then "ccache-links-clang" else "ccache-links-gcc";
          });
        };
        swapped = if ccache.enable then prev.overrideCC withMold ccacheCC else withMold;

        /*
          The intra-ISA PATH collision that used to be patched here now lives in
          the fork, where it belongs: pkgs/build-support/setup-hooks/
          cc-intra-isa-cross.sh, injected by pkgs/stdenv/cross/default.nix. It
          affects every intra-ISA cross build, not only the tuned set, so a
          per-flake overlay was the wrong layer for it.
        */
      in
      if ccache.enable then prev.overrideCC withMold ccacheCC else withMold;

    # Only swap through an argument the package actually declares. abseil-cpp
    # takes no `stdenv` at all and `.override { stdenv = ...; }` throws
    # "called with unexpected argument"; a wrong guess must degrade to
    # "untouched", never to an eval error in the middle of the system closure.
    # lib.functionArgs copes with both shapes of `override` (makeOverridable's
    # functor attrset, or a bare lambda) where `.__functionArgs` does not.
    takes = pkg: arg: lib.isAttrs pkg && pkg ? override && (lib.functionArgs pkg.override) ? ${arg};

    swapIn =
      pkg: arg: useMold:
      let
        tuned = mkStdenv { inherit useMold; } prev.${arg};
        # Version shims like protobuf_35 = callPackage ./35.nix { } expose only
        # `callPackage` to override; thread the stdenv through it into the
        # generic below, but only if that generic actually takes it.
        viaCallPackage =
          fn: a:
          let
            f = if lib.isFunction fn then fn else import fn;
          in
          prev.callPackage f (if (lib.functionArgs f) ? ${arg} then a // { ${arg} = tuned; } else a);
      in
      # callPackage FIRST when both are declared. A version shim like
      #   mbedtls = { callPackage, lib, stdenv, ... }: callPackage ./generic.nix { }
      # declares `stdenv` but never forwards it, so overriding that argument is
      # a no-op -- measured: mbedtls.override { stdenv = clangStdenv; } yields a
      # byte-identical drvPath. The inner build takes its stdenv from
      # callPackage's auto-args instead, so that is where it has to be injected.
      # Both are set when both exist, since the shim may use `stdenv` for a
      # platform test of its own.
      if takes pkg "callPackage" then
        pkg.override (
          { callPackage = viaCallPackage; } // lib.optionalAttrs (takes pkg arg) { ${arg} = tuned; }
        )
      else if takes pkg arg then
        pkg.override { ${arg} = tuned; }
      else
        pkg;

    # LAZY, and that is the whole point. Deciding membership uses only the
    # has-attr test, which forces `prev` to WHNF and nothing else; the treatment
    # itself sits unevaluated inside `value`. Running tryEval out here instead
    # forces all ~1900 packages while the package set is still being built,
    # which is infinite recursion (measured). The tryEval inside `value` gives
    # tolerance without eagerness: a package that throws on access falls back to
    # the untouched original, which then throws exactly as it would have.
    tryList =
      n: f:
      if prev ? ${n} then
        [
          {
            name = n;
            value =
              let
                t = builtins.tryEval (f prev.${n});
              in
              if t.success then t.value else prev.${n};
          }
        ]
      else
        [ ];

    treatName =
      e:
      tryList e.attr (
        pkg:
        let
          arg = e.stdenvArg or "stdenv";
        in
        if takes pkg arg || takes pkg "callPackage" then swapIn pkg arg (e.mold or true) else pkg
      );

    # Scope members are not top-level attributes. qt6 hands every module an
    # explicit stdenv from its own argument, so overrideScope cannot reach them
    # and the top-level override is the one that works; kdePackages has no
    # `stdenv` member at all, so one must be added to its scope.
    treatScope =
      e:
      tryList e.scope (
        scope:
        if takes scope "stdenv" then
          scope.override { stdenv = mkStdenv { useMold = e.mold or true; } prev.stdenv; }
        else
          scope.overrideScope (
            _: sp: { stdenv = mkStdenv { useMold = e.mold or true; } (sp.stdenv or prev.stdenv); }
          )
      );

    # Composed ON TOP of whatever the passes above produced for the same name,
    # never as a competing entry: listToAttrs keeps the FIRST binding, so a
    # separate entry for a name that `extras` also produces is silently dropped
    # (measured -- webkitgtk kept its debug output).
    debugOff =
      treated: n:
      if prev ? ${n} then
        [
          {
            name = n;
            value =
              let
                src = treated.${n} or prev.${n};
                t = builtins.tryEval (
                  lib.isDerivation src && src ? overrideAttrs
                );
              in
              if t.success && t.value then
                src.overrideAttrs (_: { separateDebugInfo = false; })
              else
                src;
          }
        ]
      else
        [ ];

    extraNames = map (e: e.attr) extras;
    # extras win over the classifier-driven pass, so a package listed there
    # with a non-default stdenv argument is not also swapped through `stdenv`.
    fromClassifier = builtins.filter (
      n: !(builtins.elem n skip) && !(builtins.elem n extraNames)
    ) names;
    treated = builtins.listToAttrs (
      builtins.concatMap (n: treatName { attr = n; mold = !(builtins.elem n moldExclude); }) fromClassifier
      ++ builtins.concatMap treatName extras
      ++ builtins.concatMap treatScope scopes
    );
  in
  treated // builtins.listToAttrs (builtins.concatMap (debugOff treated) noDebugInfoNames)
