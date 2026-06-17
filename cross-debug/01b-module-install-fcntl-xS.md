# Module-Install / HTTP-Server-Simple: `use Fcntl` in Bundled `inc/Module/Install/Makefile.pm`

**Packages:** `HTTP-Server-Simple`, any CPAN package bundling Module::Install
**File:** `pkgs/development/perl-modules/generic/default.nix`

## Symptom

```
Can't locate Fcntl.pm in @INC
  at inc/Module/Install/Makefile.pm line 6.
BEGIN failed--compilation aborted at inc/Module/Install/Makefile.pm line 6.
```

## Root Cause

`inc/Module/Install/Makefile.pm` (bundled by many CPAN packages) has at the top:

```perl
use Fcntl qw/:flock :seek/;
```

`Fcntl` is an XS module that provides `LOCK_EX`, `LOCK_SH`, `SEEK_SET`, etc. as
constants. It is unavailable in cross mini-perl. `flock` and `seek` are Perl
built-ins — only the constants are missing.

Originally noticed in HTTP-Server-Simple, but it affects every package that bundles
Module::Install.

## Fix

Moved to the generic `buildPerlPackage` cross `postPatch` in `generic/default.nix`:

```bash
if [ -f inc/Module/Install/Makefile.pm ]; then
  sed -i \
    's|^use Fcntl qw.*$|use constant { LOCK_EX => 2, LOCK_SH => 1, LOCK_UN => 8, LOCK_NB => 4, SEEK_SET => 0, SEEK_CUR => 1, SEEK_END => 2 };|' \
    inc/Module/Install/Makefile.pm
fi
```

The constants are defined inline using `use constant`, which is pure Perl. Values
match POSIX standard definitions.
