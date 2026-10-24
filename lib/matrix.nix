/*
  The evaluation matrix: synthetic variants of the REAL hosts with every
  optional piece (README "Optional pieces") switched on or off, to prove that
  "everything optional" is true rather than claimed -- all off, all on, each
  alone, the combinations that matter, and the combinations that are invalid
  BY DESIGN, which must fail with the assertion that says why. Evaluation
  only: scripts/eval-matrix.sh forces each variant's toplevel drvPath with
  builds disabled and never builds one.

  A variant is the real host file plus one extra module. The real
  nixosConfigurations never see that module (flake.nix passes it through
  mkHostWith's extraModules, empty for them), so nothing here can move a real
  host's derivation.

  PIECES. Each entry of `pieces` below is one optional piece with an `on` and
  an `off` module (functions of the variant context) and, optionally, a
  registry edit (`registry`, for the pieces whose switch a registry fact must
  agree with). Every variant names the pieces it turns ON; every other piece
  is explicitly OFF. So a variant does not inherit anything from the host
  file except what the pieces leave to it -- "off" is all-off on every host,
  whatever the host has. The one exception is the `host` variant, which forces
  nothing (below). A NEW PIECE IS ONE ENTRY in `pieces` (and its name in
  `all`); the each-alone variant appears by itself.

  "On" means the host's own settings where the host has them, and the
  smallest synthetic setting that makes the piece meaningful where it does
  not: ccache on dell-latitude (which has none), a btrfs root on dell-latitude
  (ext4 there -- the variant is "this host after a reformat"), an @root /
  @persist layout on victus-15 for impermanence, and a synthetic overlay
  guest (as in tests/guest-overlay.nix) for guest-overlay, which does nothing
  without one.

  TUNING IS RAW-IMPORTED (flake.nix tuningRawOf), so a variant cannot turn it
  off by module alone: the nixpkgs input is chosen before the module system
  exists. Each variant therefore hands mkHostWith its own `tuningRaw` AND
  forces the same values in its module, which keeps tuning/nixos.nix's
  agreement assertion satisfied -- it compares the two, and a variant that
  only did one half would fail it, which is the assertion working.

  TUNING LEVERS: march, lto, o3, heavy.
    march   my.tuning.enable + march (the host's own arch) and the levers that
            only make sense with it at their host values: intraISACross,
            upstreamTools, qtPatches, refreshTool. Off = plain upstream
            nixpkgs, those forced off. On a host with no march (dell-latitude)
            there is nothing to turn on: the lever is a no-op there.
    lto/o3  their own enable, independent of march. Alone (`lto`, `o3`)
            they run on plain upstream nixpkgs and tune the one native set,
            with build tools pointed back at upstream (tuning/nixos.nix,
            NATIVE ISOLATION); `lto-o3` is both, natively; `march-lto` and
            `march-o3` are the IntraISACross combination. All must evaluate.

            Measured 2026-10-17 on galaxybook4-pro360, closure of `lto`
            against `off` by OUTPUT path (drv paths over-count: a tuned curl
            changes every fetchurl .drv without changing one output): 541
            derivations with new outputs, all applications and their
            libraries plus 54 python3Packages pulled in through check inputs;
            no gcc, binutils, cmake, meson, ninja, python3, perl, clang, rustc
            or nodejs among them. `o3` alone: 814, the same.
    heavy   my.tuning.heavy (mold + ccache over the tuned set). Without march
            its overlay is inert; it must still evaluate.
  OTHER PIECES:
    ccache  my.ccache (client, crossDerivation, builder at host values).
            Without heavy, its only consumer, tuning/heavy.nix warns -- the
            ccache-alone variant must still evaluate.
    ca      my.ca-derivations.enable; packages = "tuned" (+ stripRefChecks)
            only together with march (on a host that has one), since "tuned"
            asserts it. CA alone is therefore the daemon flag only.
    btrfs-layout   /nix as its own subvolume (the host's, or @nix on a
            synthetic btrfs root).
    impermanence   requires btrfs-layout (+ rootSubvolume, persist, systemd
            initrd, which "on" supplies). Off also drops home = "impermanent"
            from the host's users, which the registry refuses without the
            host fact -- galaxybook's r0k0r.
    guest-overlay  requires btrfs-layout; on = the feature + the host fact +
            one overlay guest.
    luks    TODO: features/core/luks is being written on feat/luks-optional.
            When it lands on main, add its entry to `pieces` and its name to
            `all` (see the commented-out entry).

  INVALID BY DESIGN. Variants with `expect.fail` must FAIL to evaluate, and
  the log must contain that text -- the assertion that says why. The script
  checks both: a variant that fails for another reason (an IFD, a typo) is as
  unexpected as one that passes.

  `host`: the host file untouched (emacs aside). matrixWithEmacs.<host>.host
  is the matrix's self-check: it must equal the real host's drvPath, which
  scripts/eval-matrix.sh --with-emacs compares.

  EMACS. features/apps/emacs builds Doom through nix-doom-emacs-unstraightened,
  whose import-from-derivation needs its inputs BUILT before eval can go on.
  With builds disabled, a variant whose IFD inputs are neither in the local
  store nor on cache.nixos.org fails there -- correctly, and uninformatively,
  since it says nothing about the pieces. `matrix` (the default) therefore
  forces my.emacs.enable off, so the matrix depends on no IFD at all and runs
  on any machine; `matrixWithEmacs` keeps it.
*/
{ lib, mkHostWith, tuningRawOf, hosts }:

let
  f = lib.mkForce;
  # For the invalid-by-design variants: beats the pieces' mkForce.
  ff = lib.mkOverride 10;

  # -- registry edits ---------------------------------------------------------
  setFact =
    host: name: value: raw:
    raw
    // {
      hosts = raw.hosts // {
        features = raw.hosts.features // {
          ${host} = (raw.hosts.features.${host} or { }) // { ${name} = value; };
        };
      };
    };

  # home = "impermanent" needs the host fact; with impermanence off the
  # host's users get their persistent default back.
  dropImpermanentHomes =
    host: raw:
    let
      h = raw.hosts.hosts.${host};
      dropHome = a: if (a.home or null) == "impermanent" then removeAttrs a [ "home" ] else a;
    in
    raw
    // {
      users = lib.mapAttrs (
        n: u: if lib.elem n h.users then u // { overrides = dropHome (u.overrides or { }); } else u
      ) raw.users;
      hosts = raw.hosts // {
        hosts = raw.hosts.hosts // {
          ${host} = h // { narrow = lib.mapAttrs (_: dropHome) (h.narrow or { }); };
        };
      };
    };

  # The overlay guest of tests/guest-overlay.nix.
  addGuest =
    host: raw:
    raw
    // {
      users = raw.users // {
        guest = {
          uid = 1902;
          type = "untrusted";
          overrides = {
            nix = "overlay";
            session = "home-manager";
          };
          homeActivation = "standalone";
          # Any secret will do for an evaluation.
          passwordSecret = ../age/hashed-password-benjamin.age;
        };
      };
      hosts = raw.hosts // {
        hosts = raw.hosts.hosts // {
          ${host} =
            let
              h = raw.hosts.hosts.${host};
            in
            h
            // { users = h.users ++ [ "guest" ]; }
            # Without agenix (dell-latitude keeps passwords local) the secret
            # cannot be decrypted; the guest's password is then local too.
            // lib.optionalAttrs (h ? localPasswords) { localPasswords = h.localPasswords ++ [ "guest" ]; };
        };
      };
    };

  /*
    The pieces. ctx = { hostName, hasMarch, marched, on (piece -> bool),
    syntheticBtrfs }. `on`/`off`: modules; `registry`: on -> raw -> raw.
  */
  pieces = {
    march = {
      on = _: {
        # Left at the host's values (the raw import agrees: tuningRawOf).
      };
      off = _: {
        my.tuning = {
          march = f null;
          intraISACross.enable = f false;
          upstreamTools.enable = f false;
          qtPatches.enable = f false;
          refreshTool.enable = f false;
        };
      };
    };
    lto = {
      on = _: { my.tuning.lto.enable = f true; };
      off = _: { my.tuning.lto.enable = f false; };
    };
    o3 = {
      on = _: { my.tuning.o3.enable = f true; };
      off = _: { my.tuning.o3.enable = f false; };
    };
    heavy = {
      on = _: { my.tuning.heavy.enable = f true; };
      off = _: { my.tuning.heavy.enable = f false; };
    };
    ccache = {
      on = _: { my.ccache.enable = f true; };
      off = _: {
        my.ccache = {
          enable = f false;
          crossDerivation.enable = f false;
          builder.enable = f false;
        };
      };
      registry = on: ctx: setFact ctx.hostName "ccache" on;
    };
    ca = {
      on = ctx: {
        my.ca-derivations = {
          enable = f true;
          packages = f (if ctx.marched then "tuned" else "none");
          stripRefChecks = f ctx.marched;
        };
      };
      off = _: {
        my.ca-derivations = {
          enable = f false;
          packages = f "none";
          stripRefChecks = f false;
        };
      };
      registry = on: ctx: setFact ctx.hostName "ca-derivations" on;
    };
    btrfs-layout = {
      on = ctx: {
        my.btrfs-layout.enable = f true;
        fileSystems."/".fsType = lib.mkIf ctx.syntheticBtrfs (f "btrfs");
      };
      off = _: { my.btrfs-layout.enable = f false; };
    };
    impermanence = {
      on =
        ctx:
        { config, ... }:
        {
          my.impermanence.enable = f true;
          my.btrfs-layout = {
            rootSubvolume = lib.mkDefault "@root";
            persist.enable = f true;
            # A swapfile on the ephemeral root is refused; galaxybook's layout
            # (@swap at /swap) is the answer, its path set below the host's.
            swap.enable = lib.mkIf config.my.swapfile.enable (f true);
          };
          my.swapfile.path = lib.mkOverride 900 "/swap/swapfile";
          boot.initrd.systemd.enable = f true;
          # impermanence asserts that every filesystem it binds into is
          # mounted in the initrd. victus-15's /home is its own filesystem
          # (found by this matrix): an impermanent victus would need this too.
          # Keyed by host: reading config.fileSystems here would recurse.
          fileSystems = lib.mkIf (lib.elem ctx.hostName [ "victus-15" ]) { "/home".neededForBoot = f true; };
        };
      off = _: { my.impermanence.enable = f false; };
      registry =
        on: ctx: raw:
        setFact ctx.hostName "impermanence" on (if on then raw else dropImpermanentHomes ctx.hostName raw);
    };
    guest-overlay = {
      on = _: { my.guest-overlay.enable = f true; };
      off = _: { my.guest-overlay.enable = f false; };
      registry =
        on: ctx: raw:
        setFact ctx.hostName "guest-overlay" on (if on then addGuest ctx.hostName raw else raw);
    };
    # TODO(feat/luks-optional): when features/core/luks is on main --
    # luks = {
    #   on = _: { my.luks.enable = f true; };
    #   off = _: { my.luks.enable = f false; };
    # };
    # and "luks" in `all` below.
  };

  all = lib.attrNames pieces;

  /*
    The variants. `on`: the pieces turned on (all others off). `extra`: a
    further module (for the invalid-by-design ones). `tuningRaw`: override
    what flake.nix's raw import is told. `hosts`: only these hosts (default
    all). `syntheticBtrfs`: default true. `expect`: "pass" or
    { fail = "<text the error must contain>"; }.
  */
  variants =
    lib.genAttrs all (p: { on = [ p ]; })
    // {
      off = { on = [ ]; };
      all = { on = all; };
      lto-o3 = { on = [ "lto" "o3" ]; };
      march-lto = { on = [ "march" "lto" ]; };
      march-o3 = { on = [ "march" "o3" ]; };
      march-heavy-ccache = { on = [ "march" "heavy" "ccache" ]; };
      march-ca = { on = [ "march" "ca" ]; };
      btrfs-impermanence = { on = [ "btrfs-layout" "impermanence" ]; };
      btrfs-guest-overlay = { on = [ "btrfs-layout" "guest-overlay" ]; };
      # "All on" minus the fork: everything that runs on upstream nixpkgs.
      all-but-march = { on = lib.remove "march" all; };

      # -- invalid by design --------------------------------------------------
      impermanence = {
        on = [ "impermanence" ];
        expect.fail = "my.impermanence.enable requires my.btrfs-layout.enable";
      };
      guest-overlay = {
        on = [ "guest-overlay" ];
        expect.fail = "my.guest-overlay.enable requires my.btrfs-layout.enable";
      };
      btrfs-layout-on-ext4 = {
        on = [ "btrfs-layout" ];
        syntheticBtrfs = false;
        hosts = [ "dell-latitude" ];
        expect.fail = "my.btrfs-layout: / must be btrfs";
      };
      intraISACross-nomarch = {
        on = [ ];
        extra = { my.tuning.intraISACross.enable = ff true; };
        expect.fail = "my.tuning.intraISACross.enable requires my.tuning.march to be set";
      };
      upstreamTools-nomarch = {
        on = [ ];
        extra = { my.tuning.upstreamTools.enable = ff true; };
        expect.fail = "my.tuning.upstreamTools.enable requires my.tuning.march to be set";
      };
      qtPatches-nomarch = {
        on = [ ];
        extra = { my.tuning.qtPatches.enable = ff true; };
        expect.fail = "my.tuning.qtPatches.enable requires my.tuning.enable";
      };
      ca-tuned-nomarch = {
        on = [ "ca" ];
        extra = { my.ca-derivations.packages = ff "tuned"; };
        expect.fail = ''my.ca-derivations.packages = "tuned" needs a march'd host'';
      };
      march-noenable = {
        on = [ "march" ];
        tuningRaw = h: (tuningRawOf h) // { enable = false; };
        extra = { my.tuning.enable = ff false; };
        hosts = [ "galaxybook4-pro360" "victus-15" ];
        expect.fail = "but my.tuning.enable is false";
      };

      host = { host = true; };
    };

  hostMarch = h: (tuningRawOf h).march != null;

  variantModule =
    { hostName, v, withEmacs }:
    let
      isOn = p: lib.elem p v.on;
      ctx = {
        inherit hostName;
        hasMarch = hostMarch hostName;
        # The march lever means "the host's own arch"; a host that has none
        # has nothing to turn on.
        marched = isOn "march" && hostMarch hostName;
        on = isOn;
        syntheticBtrfs = v.syntheticBtrfs or true;
      };
      unknown = lib.filter (p: !(pieces ? ${p})) v.on;
      registryEdits = lib.mapAttrsToList (p: d: d.registry (isOn p) ctx) (
        lib.filterAttrs (_: d: d ? registry) pieces
      );
    in
    assert unknown == [ ] || throw "lib/matrix.nix: unknown pieces ${toString unknown}";
    {
      imports = lib.mapAttrsToList (p: d: (if isOn p then d.on else d.off) ctx) pieces ++ [ (v.extra or { }) ];
      # tuning.enable follows the raw import of mkVariant below.
      my.tuning.enable = lib.mkIf (!ctx.marched) (f (isOn "lto" || isOn "o3"));
      my.registry.extend = raw: lib.foldl' (r: e: e r) raw registryEdits;
      my.emacs.enable = lib.mkIf (!withEmacs) (f false);
    };

  mkVariant =
    withEmacs: hostName: v:
    if v.host or false then
      mkHostWith {
        inherit hostName;
        extraModules = lib.optional (!withEmacs) { my.emacs.enable = f false; };
      }
    else
      let
        marched = lib.elem "march" v.on && hostMarch hostName;
      in
      mkHostWith {
        inherit hostName;
        tuningRaw =
          if v ? tuningRaw then
            v.tuningRaw hostName
          else if marched then
            tuningRawOf hostName
          else
            {
              enable = lib.any (p: lib.elem p v.on) [ "lto" "o3" ];
              march = null;
            };
        extraModules = [ (variantModule { inherit hostName v withEmacs; }) ];
      };

  forHost = h: lib.filterAttrs (_: v: lib.elem h (v.hosts or hosts)) variants;
  matrixFor = withEmacs: lib.genAttrs hosts (h: lib.mapAttrs (_: mkVariant withEmacs h) (forHost h));
in
{
  matrix = matrixFor false;
  matrixWithEmacs = matrixFor true;
  # Plain data for scripts/eval-matrix.sh: which variants exist per host and
  # what each is expected to do.
  matrixInfo = {
    inherit hosts;
    pieces = all;
    variantsOf = lib.genAttrs hosts (h: lib.attrNames (forHost h));
    variants = lib.mapAttrs (_: v: {
      on = v.on or null;
      expect = v.expect or "pass";
    }) variants;
  };
}
