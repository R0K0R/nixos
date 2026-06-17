# HasCompiler: Deleting `require` Lines Breaks `and`-Chain Syntax

**Package:** `perl5.42.0-namespace-clean-0.27-x86_64-unknown-linux-gnu`
**File:** `pkgs/development/perl-modules/generic/default.nix`

## Symptom

```
syntax error at Makefile.PL line 99, near "and

    unless"
Execution of Makefile.PL aborted due to compilation errors.
```

## Root Cause

The generic cross `postPatch` in `buildPerlPackage` detected `inc/ExtUtils/HasCompiler.pm`
(namespace-clean bundles it), removed the file, then ran:

```bash
sed -i -e "/require ExtUtils::HasCompiler/d" Makefile.PL
```

namespace-clean's `Makefile.PL` has this structure (lines 91–103):

```perl
) @INC )
  and
eval { require ExtUtils::HasCompiler };   # ← line 98, DELETED by sed

unless ( $INC{'ExtUtils/HasCompiler.pm'} ) {  # ← shifts to line 99
```

Deleting line 98 leaves `and` (line 97) directly before `unless` (line 99), which
is a Perl syntax error: `and` expects an expression on its right side.

## Fix

**Stop deleting `inc/ExtUtils/HasCompiler.pm`**. Instead, **replace its content**
with a pure-Perl stub that returns 0 from `can_*` functions:

```bash
printf 'package ExtUtils::HasCompiler;\nuse Exporter "import";\nour @EXPORT_OK = qw(can_compile_loadable_object can_run_compiled_code);\nour $VERSION = "999";\nsub can_compile_loadable_object { 0 }\nsub can_run_compiled_code { 0 }\n1;\n' \
  > inc/ExtUtils/HasCompiler.pm
```

With the stub in place, `require ExtUtils::HasCompiler` succeeds, no Makefile.PL
surgery needed. The `can_*` functions return 0 naturally.

Also remove the `/require ExtUtils::HasCompiler/d` sed lines — they are no longer
needed and caused this breakage.
