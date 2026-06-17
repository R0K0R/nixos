# Module-Install: Replace Makefile.PL with Plain ExtUtils::MakeMaker

**Package:** `perl5.42.0-Module-Install-1.21-x86_64-unknown-linux-gnu`
**File:** `pkgs/top-level/perl-packages.nix` (ModuleInstall postPatch)

## Problem

All approaches to make `inc/Module/Install.pm` findable failed:
- Pre-populating `inc/` and patching `use lib 'lib'` to `use lib '.'` → relative path unreliable
- Using `$(pwd)` (absolute path) in `use lib` → path in @INC but file not found
- Using `PERL5OPT=-I$(pwd)` via preConfigure → same result

Despite `/build/Module-Install-1.21` being first in @INC and postPatch apparently
creating `inc/Module/Install.pm`, Perl cannot find it. Root cause unknown (possibly
a nix sandbox or set-e propagation issue).

## Root Cause (Fundamental)

Module-Install's own Makefile.PL uses `inc::Module::Install` to install itself —
a circular bootstrap. This cannot work in cross mini-perl where the `inc/` loading
mechanism is unreliable.

## Fix

Replace Makefile.PL entirely with a plain `ExtUtils::MakeMaker` build:

```nix
postPatch = lib.optionalString (!(stdenv.buildPlatform.canExecute stdenv.hostPlatform)) ''
  printf '%s\n' \
    'use strict;' 'use warnings;' \
    'use ExtUtils::MakeMaker;' \
    'WriteMakefile(' \
    "    NAME         => 'Module::Install'," \
    "    VERSION_FROM => 'lib/Module/Install.pm'," \
    "    PREREQ_PM    => {}," \
    ');' \
    > Makefile.PL
'';
```

EUMM is always available in mini-perl (core module). Nix manages all dependencies
via `propagatedBuildInputs` so `PREREQ_PM => {}` is correct. No `inc/` pre-population,
no `use lib` patching, no PERL5OPT — all the previous complexity dropped.
