# Generic: `use inc::Module::Install` Fails With `.` in @INC in Cross Mini-Perl

**Packages:** MIME-Charset, and all CPAN packages bundling `inc/Module/Install.pm`
**File:** `pkgs/development/perl-modules/generic/default.nix`

## Symptom

```
Can't locate inc/Module/Install.pm in @INC
(@INC entries checked: . /nix/store/.../cross_perl/5.42.0 ...)
```

File exists in the tarball. `.` is first in @INC (from package's own `use lib '.';`
and/or PERL_USE_UNSAFE_INC=1). Yet Perl cannot find `./inc/Module/Install.pm`.

## Root Cause

`.` in @INC consistently fails to resolve `inc/Module/Install.pm` in cross mini-perl
builds. Root cause unknown — possibly the CWD at require-time is different from the
source root, or mini-perl has different `use lib` absolutization behavior. This is
observed across Module-Install itself (many iterations) and MIME-Charset.

## Fix

Added to the generic cross `postPatch` in `buildPerlPackage`:

```bash
if [ -f inc/Module/Install.pm ]; then
  sed -i "s|use inc::Module::Install|use lib \"$(pwd)/inc\"; use Module::Install|g" \
    Makefile.PL 2>/dev/null || true
fi
```

`$(pwd)` is bash command substitution expanded at postPatch time (source root CWD).
The resulting `use lib "/build/PkgName/inc"` adds the absolute path to @INC, then
`use Module::Install` loads `Module/Install.pm` from that absolute directory — i.e.
the same bundled `inc/Module/Install.pm` file, via an unambiguous path.

Module::Install finds its plugins correctly because `$INC{'Module/Install.pm'}` is
set to the absolute path, and it derives the plugin directory from that.
