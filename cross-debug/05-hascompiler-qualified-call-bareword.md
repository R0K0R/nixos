# HasCompiler: Qualified Call Leaves `ExtUtils::HasCompiler::0` Bareword

**Package:** `perl5.42.0-namespace-clean-0.27-x86_64-unknown-linux-gnu`
**File:** `pkgs/development/perl-modules/generic/default.nix`

## Symptom

```
Bareword "ExtUtils::HasCompiler::0" not allowed while "strict subs" in use
at Makefile.PL line 108.
```

## Root Cause

The generic postPatch sed:

```bash
sed -i -e "s/can_compile_loadable_object([^)]*)/0/g" Makefile.PL
```

namespace-clean's `Makefile.PL` line 105 is:

```perl
$ucp = ExtUtils::HasCompiler::can_compile_loadable_object(quiet => 1)
```

The pattern matches only `can_compile_loadable_object(quiet => 1)`, replacing it
with `0`, but leaving `ExtUtils::HasCompiler::` in front:

```perl
$ucp = ExtUtils::HasCompiler::0   # ← bareword, invalid under strict
```

## Fix

Add sed patterns for the fully-qualified forms **before** the unqualified patterns:

```bash
sed -i \
  -e "s/ExtUtils::HasCompiler::can_run_compiled_code([^)]*)/0/g" \
  -e "s/ExtUtils::HasCompiler::can_compile_loadable_object([^)]*)/0/g" \
  -e "s/can_run_compiled_code([^)]*)/0/g" \
  -e "s/can_compile_loadable_object([^)]*)/0/g" \
  Makefile.PL 2>/dev/null || true
```

Qualified patterns run first (replacing the full `Package::func(args)` with `0`),
then unqualified patterns handle bare `func(args)` calls.
