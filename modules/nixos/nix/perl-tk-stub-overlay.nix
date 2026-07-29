/*
  Perl-Tk (perlPackages.Tk 804.036) fails to build against Perl 5.42: its
  C glue (tkGlue.c) calls `pregcomp` with three arguments and reaches into
  `struct regexp`/`struct pmop` fields that no longer exist in this Perl's
  headers -- a genuine, currently-unresolved upstream incompatibility, not
  something specific to this fork or nixpkgs. Confirmed still open against
  Perl 5.38+ upstream: github.com/eserte/perl-tk/issues/104.

  Root cause, verified against this Perl's actual CORE headers:
    - `struct regexp` DOES have the modern `offs` field Tk's "new style"
      branch expects -- Tk's own detection probe (config/perlrx.c) simply
      fails to correctly identify this under Nix's build environment, so
      it falls back to the old `startp`/`endp` fields, which are gone.
    - But even fixing that probe is not enough: `pregcomp` itself changed
      shape, from `(char *start, char *end, U32|PMOP* flags)` to
      `(SV *pattern, U32 flags)`. Both of Tk's branches still call the old
      3-argument form. A correct fix means building an SV from the Tcl
      pattern string and calling the real 2-argument API, getting UTF-8
      and case-fold flag handling right in the process -- real surgery on
      reference-counted Perl internals, not a probe fix.

  This is scoped to the FLAKE, not the fork: the fix above is real
  engineering work on someone else's C code, distinct from every other
  patch this session carries in the fork (which are all either genuine
  fork-specific pseudo-cross issues, or narrow, verified upstream bugs).
  Deferred here rather than rushed.

  Tk is a build-time-only input for a handful of texlive utilities'
  *optional* Tk-based GUI mode (tlmgr --gui, texdoctk, ptex-fontmaps'
  config tool) -- none of it is exercised by a plain texlive.combine
  build. Skip the actual module build (buildPhase/installPhase are
  overridden below, so myConfig's wrong-but-otherwise-harmless probe
  decision, made during configurePhase, is never acted on) and ship an
  empty Tk.pm so `perl.withPackages (ps: [ Tk ])` still finds a
  structurally valid module to satisfy those tools' build inputs.
  `tlmgr --gui`/texdoctk become non-functional; tlmgr CLI,
  texlive.combine, and every LaTeX package are unaffected.
*/
final: prev: {
  perlPackages = prev.perlPackages // {
    Tk = prev.perlPackages.Tk.overrideAttrs (old: {
      buildPhase = "true";
      installPhase = ''
        mkdir -p $out/lib/perl5/site_perl
        echo "package Tk; 1;" > $out/lib/perl5/site_perl/Tk.pm
      '';
      doCheck = false;
    });
  };
}
