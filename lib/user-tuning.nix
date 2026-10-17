/*
  A user's package set from their home's my.tuning (lib/home-tuning.nix).
  docs/multiuser-design.md, "Per-user tuning".

  STILL ONE NIXPKGS. The fork is upstream at the same revision plus patches,
  so every choice is the same pin instantiated differently: every library is
  the same version as the system's. Where the fork's patches make a library
  differ between the user's set and the system's, and the system loads its
  build into the user's processes, lib/surface-check.nix refuses the home.

  HOW. The host's own set as the eval matrix builds its variants
  (lib/matrix.nix): the REAL host file through mkHostWith with the three
  levers forced, plus the user's per-package names as the levers' internal
  `force` and extra `exclude`. Everything else stays the host's: hardware and
  feature overlays, ccache/heavy, CA -- except CA's "tuned" package policy,
  which needs march. A choice equal to the host's, with no per-package
  names, returns the host's pkgs value itself: every home that never sets
  my.tuning is unchanged.
*/
{ lib, mkHostWith, tuningRawOf }:

let
  # What the host itself does, in the same terms (march: null | arch).
  hostLevers = nixos: {
    march = if nixos.config.my.tuning.enable then nixos.config.my.tuning.march else null;
    lto = nixos.config.my.tuning.lto.enable;
    o3 = nixos.config.my.tuning.o3.enable;
  };

  # A home's my.tuning value -> the levers it ends up with on this host.
  resolve =
    t: hostName: nixos:
    let
      h = hostLevers nixos;
      hostMarch = (tuningRawOf hostName).march;
    in
    {
      march =
        if t.march == "system" then
          h.march
        else if t.march == false then
          null
        else if t.march == true then
          (if hostMarch != null then hostMarch else throw ''
            my.tuning.march = true on ${hostName}, which has no march of its own.
            Name the arch instead: my.tuning.march = "<gcc arch>";'')
        else
          t.march;
      lto = if t.lto == "system" then h.lto else t.lto;
      o3 = if t.o3 == "system" then h.o3 else t.o3;
    };

  perPackage = t: t.packages.o3 ++ t.packages.lto ++ t.exclude.o3 ++ t.exclude.lto;

  check =
    t: lv: nixos:
    let
      off = lib.filter (l: t.packages.${l} != [ ] && !lv.${l}) [ "o3" "lto" ];
      o3Claims = lib.optionals lv.o3 (nixos.config.my.tuning.o3.candidates ++ t.packages.o3);
      both = lib.filter (n: lib.elem n o3Claims) t.packages.lto;
    in
    if off != [ ] then
      throw ''
        my.tuning.packages.${lib.head off} lists ${toString t.packages.${lib.head off}}, but the
        ${lib.head off} lever is off in this home's package set (my.tuning.${lib.head off} resolves
        to false here). Turn it on (my.tuning.${lib.head off} = true;) or drop the list.''
    else if both != [ ] then
      throw ''
        my.tuning.packages.lto lists ${toString both}, which the o3 lever already tunes in this
        home's set (o3 candidates or my.tuning.packages.o3). A package gets one of the two:
        drop it from packages.lto, or exclude it from o3 (my.tuning.exclude.o3).''
    else
      lv;

  variantModule =
    hostRawMarch: lv: t:
    let
      f = lib.mkForce;
      marchOn = lv.march != null;
    in
    {
      my.tuning =
        {
          enable = f (marchOn || lv.lto || lv.o3);
          march = f lv.march;
          o3.enable = f lv.o3;
          lto.enable = f lv.lto;
          # Lists merge: added to whatever the host file says.
          o3.force = t.packages.o3;
          lto.force = t.packages.lto;
          o3.exclude = t.exclude.o3;
          lto.exclude = t.exclude.lto;
        }
        # Without march, the levers that exist only for the IntraISACross split
        # go too (each asserts march).
        // lib.optionalAttrs (!marchOn) {
          intraISACross.enable = f false;
          upstreamTools.enable = f false;
          qtPatches.enable = f false;
          refreshTool.enable = f false;
        }
        # march on a host that has none: the split and its upstream build
        # tools, the two levers march needs to be the configuration both hosts
        # run. qtPatches stays the host's -- it is the fork's meteorlake qtbase.
        // lib.optionalAttrs (marchOn && hostRawMarch == null) {
          intraISACross.enable = f true;
          upstreamTools.enable = f true;
        };
      my.ca-derivations = lib.mkIf (!marchOn) {
        packages = f "none";
        stripRefChecks = f false;
      };
    };
in
{
  inherit hostLevers resolve;

  # Whether a my.tuning value gives the host's own set (what pkgsFor checks).
  isHostSet = t: hostName: nixos: resolve t hostName nixos == hostLevers nixos && perPackage t == [ ];

  /*
    pkgsFor tuning hostName nixos -> the package set a home with this
    my.tuning value is built from on this host.
  */
  pkgsFor =
    t: hostName: nixos:
    let
      lv = check t (resolve t hostName nixos) nixos;
    in
    if lv == hostLevers nixos && perPackage t == [ ] then
      nixos.pkgs
    else
      (mkHostWith {
        inherit hostName;
        tuningRaw = {
          enable = lv.march != null || lv.lto || lv.o3;
          inherit (lv) march;
        };
        extraModules = [ (variantModule (tuningRawOf hostName).march lv t) ];
      }).pkgs;
}
