# Module-Install: Author Mode Triggered by `use lib 'lib'`

**Package:** `perl5.42.0-Module-Install-1.21-x86_64-unknown-linux-gnu`
**File:** `pkgs/top-level/perl-packages.nix` (ModuleInstall entry)

## Symptom

```
Compilation failed in require at lib/Module/Install/Admin/Compiler.pm line 5.
Compilation failed in require at inc/Module/Install.pm line 309.
Cannot find an extension with method 'write_meta' at inc/Module/Install/Admin.pm line 189.
```

## Root Cause

Module-Install's `Makefile.PL` has `use lib 'lib'` which prepends `lib/` to `@INC`.
When Perl processes `use inc::Module::Install`, it searches for `inc/Module/Install.pm`
in each `@INC` entry. With `lib/` first, it finds `lib/inc/Module/Install.pm` — the
**author-bootstrap** version — before our pre-populated `./inc/Module/Install.pm`.

The author bootstrap sets `AUTHOR=1`, loads `Admin::` submodules (`Admin::Compiler`,
`Admin::Metadata`, etc.) which require XS modules (`B`, `File::Glob`, `File::Remove`)
unavailable in cross mini-perl.

## Fix

In `postPatch` for Module-Install, replace `use lib 'lib'` with `use lib '.'`:

```bash
sed -i "s|^use lib 'lib';|use lib '.'|" Makefile.PL
```

This puts the source root (`.`) at the front of `@INC` instead of `lib/`, so
`./inc/Module/Install.pm` (pre-populated in postPatch) is found first → non-author mode.

Also: `cp lib/Module/Install/*.pm inc/Module/Install/` copies `Admin.pm` at the top
level — remove it to prevent `find_extensions` from loading the Admin coordinator:

```bash
rm -f inc/Module/Install/Admin.pm
```
