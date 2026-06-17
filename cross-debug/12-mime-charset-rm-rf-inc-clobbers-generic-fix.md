# MIME-Charset: Per-Package `rm -rf inc` Clobbers Generic `use lib` Fix

**Package:** `perl5.42.0-MIME-Charset-1.013.1-x86_64-unknown-linux-gnu`
**File:** `pkgs/top-level/perl-packages.nix` (MIMECharset entry)

## Symptom

```
Can't locate Module/Install.pm in @INC
(@INC entries checked: /build/MIME-Charset-1.013.1/inc . /nix/store/...cross_perl/5.42.0 ...)
at Makefile.PL line 4.
```

The generic cross postPatch in `buildPerlPackage` correctly patched `Makefile.PL` line 4
from `use inc::Module::Install` to `use lib "/build/MIME-Charset-1.013.1/inc"; use Module::Install;`.
The absolute path IS in @INC (visible in the error). The file IS in the tarball
(`inc/Module/Install.pm` exists). But Perl can't find it.

## Root Cause

**Order of postPatch execution:**

1. Generic cross postPatch (`buildPerlPackage`) runs first:
   - Detects `inc/Module/Install.pm` exists → patches `Makefile.PL` to reference `$(pwd)/inc`
   - Stubs `inc/Module/Install/Makefile.pm` Fcntl constants

2. Per-package `postPatch = "rm -rf inc"` runs second:
   - Deletes the entire `inc/` directory

At configure time, the path `/build/MIME-Charset-1.013.1/inc` is in @INC (injected by
`use lib` in patched `Makefile.PL`) but the directory no longer exists — hence the error.

The `rm -rf inc` + `nativeBuildInputs = [ ModuleInstall ]` approach was a native-build
workaround: native perl can load the system Module::Install from nativeBuildInputs. But
for cross builds, the system Module::Install is NOT in the mini-perl's @INC (different
perl installation), so deleting inc/ leaves no usable Module::Install.

## Fix

Make `rm -rf inc` and `nativeBuildInputs = [ ModuleInstall ]` conditional on native builds only:

```nix
nativeBuildInputs = lib.optional (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ModuleInstall;
postPatch = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) "rm -rf inc";
```

For cross builds:
- `inc/` is preserved → generic fix's `use lib "$(pwd)/inc"` path is valid at configure time
- Generic cross postPatch stubs `inc/Module/Install/Makefile.pm` Fcntl constants
- `inc/Module/Install.pm` is loaded as `Module::Install` from the absolute inc/ path
