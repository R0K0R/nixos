# 17 — HTML-Tree: missing configurePhase when switching from Module::Build to make

## Symptom

```
no configure script, doing nothing
Running phase: buildPhase
make: *** No targets specified and no makefile found.  Stop.
```

## Background

cross-debug-2/04 documents the root cause: Module::Build's `delete_filetree`
crashes in pseudo-cross builds due to `Cwd::fastcwd()` returning a path with a
trailing newline (Perl 5.42 + pseudo-cross). The fix switches HTML-Tree to use
`Makefile.PL` + `make` instead of `Build.PL` + `./Build`.

## Root cause of this follow-up failure

The fix in `perl-packages.nix` overrode `buildPhase`, `installPhase`, and
`checkPhase` to use `make`, but did not override `configurePhase`. The default
`configurePhase` from `buildPerlModule` calls `perl Build.PL` (Module::Build),
which generates a `Build` script — not a `Makefile`. When `buildPhase` then runs
`make`, there is no Makefile and the build fails immediately.

## Fix

Also override `configurePhase` to run `perl Makefile.PL` instead:

```nix
}).overrideAttrs (old: {
  configurePhase = "runHook preConfigure; perl Makefile.PL; runHook postConfigure";
  buildPhase = "runHook preBuild; make; runHook postBuild";
  installPhase = "runHook preInstall; make install; runHook postInstall";
  checkPhase = "runHook preCheck; make test; runHook postCheck";
});
```

HTML-Tree ships both `Build.PL` and `Makefile.PL`, so switching configure to
`perl Makefile.PL` is valid — it generates a standard `Makefile` that `make`
can then use.

## Where fixed

`/home/r0k0r/nixpkgs-contrib/pkgs/top-level/perl-packages.nix` (HTMLTree entry)

Note: the fix must be in `perl-packages.nix` directly, not in the overlay's
`perlPackages.overrideScope`. `perl.withPackages` creates a fresh instantiation
of `perl-packages.nix` via `callPackage` inside the perl derivation; top-level
`perlPackages` overlay changes do not reach it.

## Cross-debug category

**Non-pattern: incomplete phase override.** When switching a `buildPerlModule`
package from `Build.PL` to `Makefile.PL`, all four phases must be overridden:
configure, build, install, check. Missing `configurePhase` leaves the wrong build
system generating the wrong artefacts.
