# HasCompiler Stub: Missing `import` Method

**Package:** `perl5.42.0-Devel-GlobalDestruction-0.14-x86_64-unknown-linux-gnu`
**File:** `pkgs/development/perl-modules/generic/default.nix`

## Symptom

```
Attempt to call undefined import method with arguments ("can_compile_loadable_object")
via package "ExtUtils::HasCompiler" (Perhaps you forgot to load the package?)
at Makefile.PL line 5.
BEGIN failed--compilation aborted at Makefile.PL line 5.
```

## Root Cause

The initial HasCompiler stub:

```perl
package ExtUtils::HasCompiler;
our $VERSION = "999";
sub can_compile_loadable_object { 0 }
sub can_run_compiled_code { 0 }
1;
```

has no `import()` method. When a package calls:

```perl
use ExtUtils::HasCompiler 'can_compile_loadable_object';
```

Perl calls `ExtUtils::HasCompiler->import('can_compile_loadable_object')` to install
the function into the caller's namespace. Without `import`, this dies.

## Fix

Add `Exporter` to the stub so function imports work:

```perl
package ExtUtils::HasCompiler;
use Exporter "import";
our @EXPORT_OK = qw(can_compile_loadable_object can_run_compiled_code);
our $VERSION = "999";
sub can_compile_loadable_object { 0 }
sub can_run_compiled_code { 0 }
1;
```

`Exporter` is a pure-Perl core module, available in cross mini-perl.
