# 19 — buildPerlModule: preConfigure already calls perl Makefile.PL

## Background

This documents the investigation into why overriding `configurePhase` in a
`buildPerlModule` derivation via `overrideAttrs` does not work, and what the
correct fundamental fix is.

## How the perl builder works

`buildPerlPackage` (the base for `buildPerlModule`) uses a custom builder script
at `pkgs/development/perl-modules/generic/builder.sh`. This script does NOT
simply source `setup.sh` phases — it installs a `preConfigure` **bash function**:

```bash
oldPreConfigure="$preConfigure"
preConfigure() {
    eval "$oldPreConfigure"

    # patch perl shebangs to inject PERL5LIB use lib lines
    find . | while read fn; do ...patch shebang... done

    # run Makefile.PL with all required cross-aware args
    perl Makefile.PL AR="$AR" FULL_AR="$AR" CC="$CC" LD="$CC" CPPRUN="$CPPRUN" \
        PREFIX=$out INSTALLDIRS=site "${flagsArray[@]}" \
        PERL=$(type -P perl) FULLPERL=\"$fullperl/bin/perl\"
}
```

The default `configurePhase` (from `setup.sh` generic build) simply calls
`runHook preConfigure`, which invokes this function. The function:

1. Runs any user-supplied `preConfigure` string
2. Patches perl shebangs (the "patching ./t/..." lines in build logs)
3. Calls `perl Makefile.PL` with the correct `PREFIX`, `INSTALLDIRS`, `CC`,
   `AR`, and `FULLPERL` arguments

`buildPerlModule` extends `buildPerlPackage` by overriding only `buildPhase`,
`installPhase`, and `checkPhase` to use Module::Build's `./Build` instead of
`make`. It does NOT override `configurePhase` — so `perl Makefile.PL` ALWAYS
runs via `preConfigure`, even in `buildPerlModule` packages.

## Why overrideAttrs { configurePhase = "...perl Makefile.PL..."; } fails

Our override was:
```nix
configurePhase = "runHook preConfigure; perl Makefile.PL; runHook postConfigure";
```

This calls `perl Makefile.PL` TWICE:
1. Via `runHook preConfigure` → `preConfigure` function → `perl Makefile.PL PREFIX=$out ...`
2. Explicitly: `perl Makefile.PL` (no PREFIX, no INSTALLDIRS, no cross-aware args)

The second invocation likely overwrites the correctly-generated Makefile with a
broken one (wrong install paths), or fails and leaves the build directory in a
broken state. Because `set -e` is active, a failure in step 2 should abort —
but the observed behaviour (proceeding to buildPhase with no Makefile) suggests
the second `perl Makefile.PL` either:
- Exits 0 but writes nothing (e.g., missing required module causes early return)
- Deletes or replaces the Makefile with an empty/corrupt one

The log shows the shebang patching (from the `preConfigure` function's step 2)
but NO MakeMaker output at all — not even from the first correct invocation.
This is the open mystery: either MakeMaker's output is being captured somewhere
else, or the cross environment causes `perl Makefile.PL` to exit 0 with no output.

## Why switching to buildPerlPackage fixes it

`buildPerlPackage`'s default phases are:
- `configurePhase`: calls `runHook preConfigure` → `preConfigure` function → `perl Makefile.PL` with correct args
- `buildPhase`: `make`
- `installPhase`: `make install`
- `checkPhase`: `make test`

By switching HTML-Tree from `buildPerlModule` to `buildPerlPackage`, we:
1. Keep the correct `configurePhase` (no override needed — `preConfigure` already does it right)
2. Use `make` for build/install/check instead of Module::Build's `./Build`
3. Avoid calling `perl Makefile.PL` twice

No phase overrides are needed at all — `buildPerlPackage` is the right tool
for packages that ship `Makefile.PL`.

## Fundamental fix options

### Option A (correct workaround, current): switch to `buildPerlPackage`

For any package that ships both `Build.PL` and `Makefile.PL`, use
`buildPerlPackage` directly. No overrides needed. This is the cleanest fix
when the package has a working `Makefile.PL`.

### Option B (nixpkgs infrastructure): add `useMakeMaker` to `buildPerlModule`

Add a `useMakeMaker ? false` parameter to `buildPerlModule` that, when true,
switches `buildPhase`/`installPhase`/`checkPhase` back to `make`-based:

```nix
buildPerlModule = { useMakeMaker ? false, ... }@args:
  buildPerlPackage ({
    buildPhase = if useMakeMaker then ''
      runHook preBuild; make; runHook postBuild
    '' else ''
      runHook preBuild
      perl Build.PL --installdirs site --destdir $TMPDIR/build
      ./Build
      runHook postBuild
    '';
    ...
  } // removeAttrs args [ "useMakeMaker" ]);
```

This would let callers do `buildPerlModule { useMakeMaker = true; ... }` without
switching builder types entirely. Upstream-submittable as a general cross-compat fix.

### Option C (upstream): fix Module::Build's `delete_filetree`

Module::Build 0.4234 uses the deprecated `File::Path::rmtree` API in
`delete_filetree`, which saves/restores cwd via `Cwd::fastcwd()`. Perl 5.42
warns on stat with paths containing newlines; in pseudo-cross builds
`fastcwd()` returns a path with a trailing newline. The upstream fix is in
`File::Path` or `Cwd` — remove the trailing newline from `fastcwd()`'s
return value, or have Module::Build use `File::Path::remove_tree` (the
non-deprecated replacement that doesn't use fastcwd).

This is the deepest correct fix but requires changes to core Perl modules.

### Option D (upstream): fix `Cwd::fastcwd()`

`Cwd::fastcwd()` should strip trailing newlines from its return value. A
one-line fix in `ext/POSIX/POSIX.xs` or `lib/Cwd.pm` would solve the root
cause for all callers, not just Module::Build.

## Lesson learned

When overriding phases in a `builder.sh`-based derivation (perl, python, etc.),
first understand what `preConfigure`/`preBuild` hooks actually do — they may
already run the tool you're trying to call. Adding a redundant explicit call
can corrupt the build state rather than fix it.

`builder = ./builder.sh` packages do NOT follow the pure `setup.sh` phase
convention. Their hooks are bash functions, not strings, and may perform
substantive work beyond environment setup.
