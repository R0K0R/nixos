# Module::Install Rejects `use Module::Install` — Must Use `use inc::Module::Install`

**Packages:** MIME-Charset, HTTP-Server-Simple (and all packages bundling `inc/Module/Install.pm`)
**File:** `pkgs/development/perl-modules/generic/default.nix`

## Symptom

```
Please invoke Module::Install with:

        use inc::Module::Install;

not:

        use Module::Install;

BEGIN failed--compilation aborted at Makefile.PL line N.
```

## Root Cause

The bundled `inc/Module/Install.pm` has an explicit safety check that detects when it
was loaded via `use Module::Install` instead of `use inc::Module::Install` and dies.
Our previous generic fix replaced `use inc::Module::Install` with
`use lib "$(pwd)/inc"; use Module::Install` — which triggered this rejection.

## Fix

Change the sed replacement to keep `use inc::Module::Install` but PREPEND a
`use lib "$(pwd)"` that adds the package root (not `inc/`) to @INC as an absolute path.
`use inc::Module::Install` then finds `inc/Module/Install.pm` under the package root.

```bash
if [ -f inc/Module/Install.pm ]; then
  sed -i "s|use inc::Module::Install|use lib \"$(pwd)\"; use inc::Module::Install|g" \
    Makefile.PL 2>/dev/null || true
fi
```

Result in Makefile.PL (e.g., for MIME-Charset):
```perl
use lib '.';
use lib "/build/MIME-Charset-1.013.1"; use inc::Module::Install;
```

`use inc::Module::Install` looks for `inc/Module/Install.pm` in each @INC entry.
With `/build/MIME-Charset-1.013.1` in @INC, it finds
`/build/MIME-Charset-1.013.1/inc/Module/Install.pm`. Module::Install loads correctly
under the `inc::` namespace and its safety check is not triggered.

## Why `$(pwd)` (package root) and not `$(pwd)/inc`

When Perl handles `use inc::Module::Install`, it looks for `inc/Module/Install.pm`
relative to each @INC entry. So @INC must contain the PARENT of `inc/`, i.e. the
package root — NOT `inc/` itself. Adding `$(pwd)/inc` to @INC would make Perl look
for `inc/inc/Module/Install.pm` which doesn't exist.
