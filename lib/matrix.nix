/*
  The evaluation matrix: synthetic variants of the REAL hosts with the
  optional build levers toggled, to prove that "everything optional" is true
  rather than claimed. Evaluation only -- scripts/eval-matrix.sh forces each
  variant's toplevel drvPath with builds disabled and never builds one.

  A variant is the real host file plus one extra module of mkForce's. The
  real nixosConfigurations never see that module (flake.nix passes it through
  mkHostWith's extraModules, empty for them), so nothing here can move a real
  host's derivation.

  TUNING IS RAW-IMPORTED (flake.nix tuningRawOf), so a variant cannot turn it
  off by module alone: the nixpkgs input is chosen before the module system
  exists. Each variant therefore hands mkHostWith its own `tuningRaw` AND
  forces the same values in its module, which keeps tuning/nixos.nix's
  agreement assertion satisfied -- it compares the two, and a variant that
  only did one half would fail it, which is the assertion working.

  LEVERS: march, lto, o3, ccache, ca.
    march   my.tuning.enable + march (the host's own arch) and the levers that
            only make sense with it at their host values: intraISACross,
            upstreamTools, qtPatches, refreshTool. Off = plain upstream
            nixpkgs, those forced off.
    lto/o3  their own enable, independent of march. Alone (`lto`, `o3`)
            they run on plain upstream nixpkgs and tune the one native set,
            with build tools pointed back at upstream (tuning/nixos.nix,
            NATIVE ISOLATION); `lto-o3` is both, natively; `march-lto` and
            `march-o3` are the IntraISACross combination. All must evaluate.
            They used to assert march, and two *-nomarch variants expected
            that to fire.

            Measured 2026-10-17 on galaxybook4-pro360, closure of `lto`
            against `off` by OUTPUT path (drv paths over-count: a tuned curl
            changes every fetchurl .drv without changing one output): 541
            derivations with new outputs, all applications and their
            libraries plus 54 python3Packages pulled in through check inputs;
            no gcc, binutils, cmake, meson, ninja, python3, perl, clang, rustc
            or nodejs among them. `o3` alone: 814, the same.
    ccache  my.ccache (client, crossDerivation, builder at host values) and
            my.tuning.heavy, its only consumer. Without march heavy's overlay
            is inert and tuning/heavy.nix warns; that is the point of the
            ccache-alone variant: it must still evaluate.
    ca      my.ca-derivations.enable; packages = "tuned" (+ stripRefChecks)
            only together with march (on a host that has one), since "tuned"
            asserts it. CA alone is
            therefore the daemon flag only.

  EMACS. features/apps/emacs builds Doom through nix-doom-emacs-unstraightened,
  whose import-from-derivation needs its inputs BUILT before eval can go on.
  With builds disabled, a variant whose IFD inputs are neither in the local
  store nor on cache.nixos.org fails there -- correctly, and uninformatively,
  since it says nothing about the levers. `matrix` (the default) therefore
  forces my.emacs.enable off, so the matrix depends on no IFD at all and runs
  on any machine; `matrixWithEmacs` keeps it.

  Measured 2026-10-17 on galaxybook: matrixWithEmacs evaluated every variant
  too, because the doom IFD's inputs were already present for both package
  sets (the native-elisp change builds them on the generic Emacs, so they
  hardly depend on the levers). That is a property of that store on that
  day, not a guarantee -- hence the emacs-free default. matrixWithEmacs.<host>.all
  is also the matrix's self-check: it must equal the real host's drvPath
  (it did, for both hosts).
*/
{ lib, mkHostWith, tuningRawOf, hosts }:

let
  off = { march = false; lto = false; o3 = false; ccache = false; ca = false; };

  variants = {
    off = { levers = off; expect = "pass"; };
    march = { levers = off // { march = true; }; expect = "pass"; };
    lto = { levers = off // { lto = true; }; expect = "pass"; };
    o3 = { levers = off // { o3 = true; }; expect = "pass"; };
    lto-o3 = { levers = off // { lto = true; o3 = true; }; expect = "pass"; };
    march-lto = { levers = off // { march = true; lto = true; }; expect = "pass"; };
    march-o3 = { levers = off // { march = true; o3 = true; }; expect = "pass"; };
    ccache = { levers = off // { ccache = true; }; expect = "pass"; };
    ca = { levers = off // { ca = true; }; expect = "pass"; };
    all = { levers = { march = true; lto = true; o3 = true; ccache = true; ca = true; }; expect = "pass"; };
  };

  variantModule =
    { levers, withEmacs, hostMarch }:
    let
      f = lib.mkForce;
      lv = levers;
      # The march lever means "the host's own arch". A host that has none
      # (untuned: dell-latitude) has nothing to turn on, so the tuned package
      # policy -- which asserts a march'd host -- stays at "none" there.
      marched = lv.march && hostMarch;
      offUnless = c: lib.mkIf (!c) (f false);
    in
    {
      my.tuning = {
        enable = lib.mkIf (!lv.march) (f (lv.lto || lv.o3));
        march = lib.mkIf (!lv.march) (f null);
        o3.enable = f lv.o3;
        lto.enable = f lv.lto;
        intraISACross.enable = offUnless lv.march;
        upstreamTools.enable = offUnless lv.march;
        qtPatches.enable = offUnless lv.march;
        refreshTool.enable = offUnless lv.march;
        heavy.enable = f lv.ccache;
      };
      my.ccache = {
        enable = f lv.ccache;
        crossDerivation.enable = offUnless lv.ccache;
        builder.enable = offUnless lv.ccache;
      };
      my.ca-derivations = {
        enable = f lv.ca;
        packages = f (if lv.ca && marched then "tuned" else "none");
        stripRefChecks = f (lv.ca && marched);
      };
      my.emacs.enable = lib.mkIf (!withEmacs) (f false);
    };

  mkVariant =
    withEmacs: hostName: v:
    mkHostWith {
      inherit hostName;
      tuningRaw =
        if v.levers.march then
          tuningRawOf hostName
        else
          { enable = v.levers.lto || v.levers.o3; march = null; };
      extraModules = [ (variantModule { inherit (v) levers; inherit withEmacs; hostMarch = (tuningRawOf hostName).march != null; }) ];
    };

  matrixFor = withEmacs: lib.genAttrs hosts (h: lib.mapAttrs (_: mkVariant withEmacs h) variants);
in
{
  matrix = matrixFor false;
  matrixWithEmacs = matrixFor true;
  # Plain data for scripts/eval-matrix.sh: which variants exist and what each
  # is expected to do.
  matrixInfo = {
    inherit hosts;
    variants = lib.mapAttrs (_: v: { inherit (v) levers expect; why = v.why or ""; }) variants;
  };
}
