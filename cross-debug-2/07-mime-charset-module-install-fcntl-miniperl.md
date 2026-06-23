# 07 — MIME-Charset / perl cross: miniperl can't load XS modules (Fcntl)

## Symptom

```
Can't locate Fcntl.pm in @INC (you may need to install the Fcntl module)
```
or:
```
dynamic loading not available in this perl
```

This blocked MIME-Charset and several other CPAN packages during `Makefile.PL`
parse time in pseudo-cross.

## Root cause (three iterations)

### Layer 1: pseudo-cross selects `perl.mini` incorrectly

`pkgs/development/perl-modules/generic/default.nix` uses
`!stdenv.buildPlatform.canExecute stdenv.hostPlatform` to decide whether to use
`perl.mini` (a minimal perl with no dynamic loading) instead of full perl for
module builds.

In pseudo-cross, `canExecute` returns **false** because nixpkgs's `canExecute`
logic in `lib/systems/default.nix` requires both platforms to have a named
`gcc.arch`, and the generic BUILD platform (`x86_64-linux`) declares none.
So pseudo-cross builds used `perl.mini` for ALL module builds — even though the
BUILD machine (yulee/znver5) can actually execute HOST binaries.

### Layer 2: MIME-Charset bundles Module::Install which calls `use Fcntl`

With `perl.mini` selected, packages that bundle `inc/` (Module::Install) fail
because `Module::Install/Makefile.pm` calls `use Fcntl` at Makefile.PL parse
time. `Fcntl` is an XS module; miniperl has no dynamic loading.

## Fix progression

**Round 1** — per-package `rm -rf inc`: Removed the bundled `inc/` in
MIMECharset so Makefile.PL would fall back to the system Module::Install.
Broke the build in a different way (system Module::Install not always present).

**Round 2** — use full perl in pseudo-cross: Guarded the mini-perl selection
with `!stdenv.isPseudoCross`:
```nix
perl = if (!stdenv.isPseudoCross) && (!stdenv.buildPlatform.canExecute stdenv.hostPlatform)
       then perl.mini else perl;
```
Reverted the per-package `rm -rf inc` override. This fixed MIME-Charset and
most other Module::Install packages.

**Round 3** — add `Fcntl` and `File::Temp` stubs to `cross_perl`: For packages
where `perl.mini` IS still correct (real cross builds where BUILD cannot execute
HOST binaries), added pure-Perl stubs:
- `Fcntl.pm`: flock flags, seek origins, O_* flags
- `File::Temp.pm`: `tempfile` + `tempdir` with proper `Exporter`/`import`

This handles any CPAN package that calls `use Fcntl` or `use File::Temp` at
parse time in real cross (not pseudo-cross).

## nixpkgs-contrib commits

- `fd8ed2f64` — per-package MIMECharset rm bundled inc/ (round 1)
- `1cceae8c6` — comment documenting canExecute root cause
- `67e91022e` — use full perl (not mini) in pseudo-cross (round 2)
- `0ff8da798` — revert round 1 per-package patch; add Fcntl per-package
- `3f18f7e9d` — Fcntl + File::Temp stubs in cross_perl (round 3)

## Cross-debug category

**Pattern G2/G3:** `strictDeps` + incorrect `canExecute` result causes wrong
perl variant selection. Fundamental fix (round 2) is in nixpkgs infrastructure
(`generic/default.nix`), gated on `isPseudoCross`.
