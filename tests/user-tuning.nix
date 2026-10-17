/*
  Per-user tuning (docs/multiuser-design.md, "Per-user tuning"), evaluation
  only (tests/user-tuning-eval.sh). Real hosts' homes and synthetic variants;
  packages are compared by drvPath, never by comparing package sets (`==` on
  a set forces every attribute, removed aliases included).
*/
{ lib, inputs, mkHostWith, nixosConfigurations, homeLib }:

let
  upstream = inputs.nixpkgs-upstream.legacyPackages.x86_64-linux;
  off = { march = false; lto = false; o3 = false; };
  hl = homeLib.victus-15;
  host = nixosConfigurations.victus-15;

  expect =
    what: cond: seen:
    if cond then seen else throw "user-tuning: ${what}: got ${seen}";
  mustFail =
    what: v:
    let
      r = builtins.tryEval (builtins.deepSeq v v);
    in
    if r.success then throw "user-tuning: ${what} was accepted, should have been refused" else "refused";
  home = tuning: hl.mkHome { username = "r0k0r"; modules = [ { my.tuning = tuning; } ]; };
  flags = p: p.NIX_CFLAGS_COMPILE or p.env.NIX_CFLAGS_COMPILE or "";
in
{
  # -- package sets ----------------------------------------------------------
  defaultIsHost = expect "a home that never sets my.tuning is built from the host's set" (
    (hl.mkHome { username = "r0k0r"; }).pkgs.hello.drvPath == host.pkgs.hello.drvPath
    && (hl.mkHome { username = "r0k0r"; }).pkgs.zstd.drvPath == host.pkgs.zstd.drvPath
  ) "host set";
  untunedIsUpstream = expect "all levers false = upstream nixpkgs" (
    (hl.pkgsFor off).hello.drvPath == upstream.hello.drvPath && (hl.pkgsFor off).zstd.drvPath == upstream.zstd.drvPath
  ) "upstream";
  perPackageLto = expect "packages.lto tunes a name in the user's set only" (
    lib.hasInfix "-flto" (flags (hl.pkgsFor { o3 = false; packages.lto = [ "jq" ]; }).jq)
    && !(lib.hasInfix "-flto" (flags host.pkgs.jq))
  ) "jq lto'd for the user";
  resolveHosts = expect "march = true is the host's own" ((hl.tuningFor { march = true; }).march == "znver3") (
    builtins.toJSON (hl.tuningFor { march = true; })
  );

  # -- system-side levers as options ------------------------------------------
  hostExclude = expect "my.tuning.o3.exclude takes a package back out" (
    (mkHostWith {
      hostName = "victus-15";
      extraModules = [ { my.tuning.o3.exclude = [ "zstd" ]; } ];
    }).pkgs.zstd.drvPath != host.pkgs.zstd.drvPath
  ) "zstd excluded";

  # -- surface compatibility ---------------------------------------------------
  surfaceOk = expect "lto off only changes flags: the home evaluates" (
    lib.hasSuffix ".drv" (home { lto = false; }).activationPackage.drvPath
  ) "evaluates";
  surfaceRefused =
    let
      r = builtins.tryEval (home off).activationPackage.drvPath;
    in
    expect "an untuned home on a march host is refused (perl/sqlite cross patches)" (!r.success) "refused";

  refused = {
    leverOff = mustFail "packages.o3 with o3 off" (hl.pkgsFor { o3 = false; packages.o3 = [ "jq" ]; }).hello.drvPath;
    o3Claims = mustFail "packages.lto on a name o3 tunes" (hl.pkgsFor { packages.lto = [ "jq" ]; }).hello.drvPath;
    integrated = mustFail "my.tuning in an integrated home" (
      (mkHostWith {
        hostName = "victus-15";
        extraModules = [ { home-manager.users.benjamin.my.tuning.lto = false; } ];
      }).config.system.build.toplevel.drvPath
    );
  };
}
