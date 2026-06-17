# Module-Install: `use lib '.'` Missing Semicolon

**Package:** `perl5.42.0-Module-Install-1.21-x86_64-unknown-linux-gnu`
**File:** `pkgs/top-level/perl-packages.nix` (ModuleInstall postPatch)

## Symptom

```
"use" not allowed in expression at Makefile.PL line 10, at end of line
syntax error at Makefile.PL line 10, near "use inc::Module::Install"
```

## Root Cause

The sed replacement string was missing the trailing semicolon:

```bash
# BAD — replacement has no ;
sed -i "s|^use lib 'lib';|use lib '.'|" Makefile.PL
```

Original: `use lib 'lib';` → After sed: `use lib '.'` (no `;`)

Makefile.PL then reads:
```perl
use lib '.'       # ← no semicolon: Perl keeps reading for more args
use inc::Module::Install;   # ← "use" not allowed in expression
```

## Fix

Add the semicolon to the replacement:

```bash
sed -i "s|^use lib 'lib';|use lib '.';|" Makefile.PL
```
