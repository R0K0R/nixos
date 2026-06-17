# Module-Install: `use lib '.'` Relative Path Unreliable at Require-Time

**Package:** `perl5.42.0-Module-Install-1.21-x86_64-unknown-linux-gnu`
**File:** `pkgs/top-level/perl-packages.nix` (ModuleInstall postPatch)

## Symptom

```
Can't locate inc/Module/Install.pm in @INC
(@INC entries checked: . /nix/store/.../cross_perl/5.42.0 ...)
```

`.` is now FIRST in `@INC` (the `use lib '.';` fix from issue #02/#07 worked),
but `inc/Module/Install.pm` still not found despite postPatch creating it.

## Root Cause

`use lib '.'` adds the literal string `'.'` to `@INC`. When Perl processes a
`require` or `use`, it resolves relative `@INC` entries against the **CWD at
require-time**. If anything shifts the CWD between patchPhase and the `use
inc::Module::Install` statement in `perl Makefile.PL`, the lookup fails.

The Perl `lib.pm` module may also attempt to absolutize paths via `Cwd::abs_path`.
With our cross Cwd stub this could silently produce a wrong path.

## Fix

Use `$(pwd)` (bash command substitution, expanded at postPatch time) to inject
the **absolute** source-root path into `Makefile.PL`:

```bash
sed -i "s|^use lib 'lib';|use lib '$(pwd)';|" Makefile.PL
```

In a Nix `''...''` string, `$(...)` is NOT Nix interpolation (only `${...}` is).
Bash expands `$(pwd)` to the absolute CWD when postPatch runs (source root).
The result is something like `use lib '/build/Module-Install-1.21';`, giving
Perl an unambiguous path to find `./inc/Module/Install.pm`.
