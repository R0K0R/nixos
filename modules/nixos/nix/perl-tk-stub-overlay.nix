/*
  Perl-Tk (perlPackages.Tk 804.036) does not build against Perl 5.42 -- a
  genuine, currently-unresolved upstream incompatibility, not a fork or a
  nixpkgs bug. Verified against Tk's actual source and this Perl's real
  CORE headers:

    - `struct regexp` DOES have the modern `offs` field that Tk's
      "new style" branch expects. Tk's build-time probe (config/perlrx.c,
      run via myConfig -> Tk::MMtry::try_compile) fails to detect this
      here, so it falls back to the old `startp`/`endp` fields, which
      Perl 5.42 no longer has.
    - Fixing the probe alone is NOT sufficient: `pregcomp` itself changed
      shape, from (char *start, char *end, U32|PMOP *flags) to
      (SV *pattern, U32 flags) -- see embed.h. Both of Tk's branches still
      call the old three-argument form, so forcing the "new style" branch
      trades the struct error for a wrong-argument-count error.

  A correct fix means building an SV from the Tcl pattern and calling the
  modern two-argument API with correct UTF-8 / case-fold flag handling:
  real surgery on reference-counted Perl internals, still open upstream as
  of Perl 5.38+ (github.com/eserte/perl-tk/issues/104). Deliberately not
  attempted in the fork.

  WHY THIS OVERRIDES `perl` AND NOT `perlPackages`
  ------------------------------------------------
  An earlier version of this overlay overrode the top-level
  `perlPackages.Tk` and did nothing at all -- texlive kept building the
  original derivation. `perl.withPackages (ps: ...)` resolves `ps` against
  perl's OWN internal scope:

      # perl/default.nix
      withPackages = f: buildEnv.override { extraLibs = f pkgs; };
      pkgs = perlPackages // (overrides pkgs);

  and the top-level attribute is derived *from* that scope, not the other
  way round (`perl5Packages = recurseIntoAttrs perl5.pkgs`), so overriding
  it is strictly downstream of every consumer that matters. The supported
  hook is perl's `overrides` argument, applied to `perl5` since
  `perl = perl5` and `perlPackages = perl5Packages` both flow from it.

  `overrides` feeds `passthruFun` only, so this does NOT change perl's own
  derivation and does NOT trigger a perl rebuild or cascade.

  Tk is a build-time-only input to a few texlive utilities' *optional*
  Tk-based GUI mode (tlmgr --gui, texdoctk, ptex-fontmaps' config tool),
  none of which a plain texlive.combine build exercises. Skip Tk's actual
  module build and ship an empty Tk.pm so `perl.withPackages (ps: [ Tk ])`
  still resolves. Those GUIs become non-functional; tlmgr CLI,
  texlive.combine, and every LaTeX package are unaffected.
*/
final: prev:

let
  # prev.perl5's ORIGINAL Tk -- referencing the overridden scope's own Tk
  # here would be self-referential (`pkgs = perlPackages // overrides pkgs`)
  # and recurse forever. perl's derivation is unchanged by `overrides`
  # (passthru only), so this is the same interpreter either way.
  stubTk = prev.perl5.pkgs.Tk.overrideAttrs (old: {
    buildPhase = "true";
    # buildPerlPackage declares outputs = [ "out" "devdoc" ], and nix fails the
    # build if a declared output directory is never created -- so $devdoc has to
    # be made even though it stays empty.
    installPhase = ''
      mkdir -p $out/${prev.perl5.libPrefix} $devdoc
      echo "package Tk; 1;" > $out/${prev.perl5.libPrefix}/Tk.pm
    '';
    doCheck = false;
    doInstallCheck = false;
  });
in
{
  perl5 = prev.perl5.override (old: {
    overrides = pkgs: (old.overrides or (_: { })) pkgs // { Tk = stubTk; };
  });
}
