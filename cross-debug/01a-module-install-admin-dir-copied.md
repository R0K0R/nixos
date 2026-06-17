# Module-Install: Admin/ Subdirectory Copied into `inc/`, Loads XS

**Package:** `perl5.42.0-Module-Install-1.21-x86_64-unknown-linux-gnu`
**File:** `pkgs/top-level/perl-packages.nix` (ModuleInstall entry)

## Symptom (first attempt)

```
Can't load 'B.so' ... Compilation failed in require at lib/Module/Install/Admin/Compiler.pm line 5.
Can't locate File/Glob.pm ... at lib/Module/Install/Admin/Metadata.pm line 7.
Bareword "tests_recursive" not allowed while "strict subs" in use at Makefile.PL
```

## Root Cause

Initial postPatch used:

```bash
cp -r lib/Module/Install inc/
```

This copied the entire `lib/Module/Install/` tree including the `Admin/` subdirectory
(`Admin/Compiler.pm`, `Admin/Metadata.pm`, etc.) into `inc/Module/Install/Admin/`.

`Module::Install::find_extensions` recursively loads ALL `.pm` files under
`inc/Module/Install/`. The Admin submodules need XS:
- `Admin::Compiler` → `B` (bytecode compiler, XS)
- `Admin::Metadata` → `File::Glob` (XS)
- etc.

None of these are available in cross mini-perl.

## Fix

Copy only top-level `.pm` files, not the `Admin/` subdirectory:

```bash
mkdir -p inc/Module/Install
cp lib/Module/Install.pm inc/
cp lib/Module/Install/*.pm inc/Module/Install/ 2>/dev/null || true
rm -f inc/Module/Install/Admin.pm
```

The `rm -f inc/Module/Install/Admin.pm` is also needed because `Admin.pm` at the
top level would trigger loading of its XS-dependent submodules.
