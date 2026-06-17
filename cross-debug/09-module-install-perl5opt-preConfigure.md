# Module-Install: Use `PERL5OPT` in `preConfigure` Instead of Patching Makefile.PL for @INC

**Package:** `perl5.42.0-Module-Install-1.21-x86_64-unknown-linux-gnu`
**File:** `pkgs/top-level/perl-packages.nix` (ModuleInstall entry)

## Symptom

Absolute path `/build/Module-Install-1.21` is in `@INC` (via `use lib '$(pwd)'`)
but `inc/Module/Install.pm` is still not found there.

## Root Cause

The `$(pwd)` bash expansion in sed runs at postPatch time in the correct directory.
The absolute path IS injected into @INC. Yet the file is not found, suggesting
`cp lib/Module/Install.pm inc/` either fails silently or the file is gone by
configure time. Root cause unclear — possibly `set -e` doesn't propagate through
the hook mechanism for some failures.

## Fix

Stop patching `Makefile.PL` for `@INC` purposes. Instead, use `preConfigure`
to export `PERL5OPT` with the absolute source path right before `perl Makefile.PL`
runs. In `builder.sh`, `preConfigure()` evaluates `$preConfigure` first via
`eval "$oldPreConfigure"`, then runs `perl Makefile.PL` — so the export persists.

```nix
preConfigure = lib.optionalString (!(stdenv.buildPlatform.canExecute stdenv.hostPlatform)) ''
  export PERL5OPT="-I$(pwd)"
'';
```

`$(pwd)` expands to the absolute CWD at the time preConfigure runs (source root).
`PERL5OPT=-I/path` is read by Perl at startup and adds the path to @INC — no
Makefile.PL surgery needed. `use lib 'lib'` is still deleted to prevent `lib/`
heading @INC (author bootstrap issue).
