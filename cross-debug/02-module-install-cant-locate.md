# Module-Install: `Can't locate inc/Module/Install.pm` After Removing `use lib 'lib'`

**Package:** `perl5.42.0-Module-Install-1.21-x86_64-unknown-linux-gnu`
**File:** `pkgs/top-level/perl-packages.nix` (ModuleInstall entry)

## Symptom

After the previous fix (deleting `use lib 'lib'`), the error changed:

```
Can't locate inc/Module/Install.pm in @INC
(@INC entries checked: .../cross_perl/5.42.0 .../5.42.0 ... .)
at Makefile.PL line 9.
```

`lib/` is gone from `@INC` (the sed worked), and `.` IS listed at the end of `@INC`
via `PERL_USE_UNSAFE_INC=1`, yet `inc/Module/Install.pm` is not found.

## Root Cause

`PERL_USE_UNSAFE_INC=1` adds `.` at the **end** of `@INC`. But this appears unreliable
for finding `inc/Module/Install.pm` in cross mini-perl builds (possibly a timing or
CWD issue with how mini-perl handles the unsafe INC env var).

## Fix

Replace `use lib 'lib'` with `use lib '.'` (rather than deleting it):

```bash
sed -i "s|^use lib 'lib';|use lib '.'|" Makefile.PL
```

`use lib '.'` calls `unshift @INC, '.'` at compile time — this is explicit, happens
before `use inc::Module::Install`, and puts `.` at the **front** of `@INC`, making
`./inc/Module/Install.pm` reliably found regardless of `PERL_USE_UNSAFE_INC` behavior.
