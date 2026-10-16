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
    lto/o3  their own enable. Both REQUIRE march today (their overlays skip
            any package set without gcc.arch, and tuning/nixos.nix asserts
            it), so "lto alone" means march + lto, and the *-nomarch
            variants exist to show that assertion firing: expected to fail.
    ccache  my.ccache (client, crossDerivation, builder at host values) and
            my.tuning.heavy, its only consumer. Without march heavy's overlay
            is inert and tuning/heavy.nix warns; that is the point of the
            ccache-alone variant: it must still evaluate.
    ca      my.ca-derivations.enable; packages = "tuned" (+ stripRefChecks)
            only together with march, since "tuned" asserts it. CA alone is
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
    lto = { levers = off // { march = true; lto = true; }; expect = "pass"; };
    o3 = { levers = off // { march = true; o3 = true; }; expect = "pass"; };
    lto-nomarch = { levers = off // { lto = true; }; expect = "fail"; why = "lto requires march (assertion)"; };
    o3-nomarch = { levers = off // { o3 = true; }; expect = "fail"; why = "o3 requires march (assertion)"; };
    ccache = { levers = off // { ccache = true; }; expect = "pass"; };
    ca = { levers = off // { ca = true; }; expect = "pass"; };
    all = { levers = { march = true; lto = true; o3 = true; ccache = true; ca = true; }; expect = "pass"; };
  };

  variantModule =
    { levers, withEmacs }:
    let
      f = lib.mkForce;
      lv = levers;
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
        packages = f (if lv.ca && lv.march then "tuned" else "none");
        stripRefChecks = f (lv.ca && lv.march);
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
      extraModules = [ (variantModule { inherit (v) levers; inherit withEmacs; }) ];
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
