# 11 — ghostscript: genarch.c `-Werror=declaration-after-statement` (GCC 15 + glibc 2.42)

## Symptom

```
genarch.c: error: declaration of 'X' after statement [-Werror=declaration-after-statement]
```

ghostscript's `configure` script adds `-Werror=declaration-after-statement` to
`CFLAGS`. With glibc 2.42, header changes in `bits/stdint-uintn.h` introduce
a C89-style declaration-after-statement pattern that triggers this warning
under GCC 15's stricter enforcement.

## Root cause

GCC 15 + glibc 2.42 combination — not pseudo-cross specific. The change surfaced
because the cross build compiled from source (no binary cache for the meteorlake
target).

## Fix (two iterations)

### Round 1 — configureFlags approach (broken)

Tried passing `-Wno-error=declaration-after-statement` via `configureFlags`.
Failed: configureFlags items are word-split by the shell, so the flag with `=`
was treated as an unknown option by `./configure`.

### Round 2 — `NIX_CFLAGS_COMPILE` (correct)

Used `env.NIX_CFLAGS_COMPILE` instead. The cc-wrapper appends `NIX_CFLAGS_COMPILE`
after all Makefile-supplied flags, so it overrides ghostscript's
`-Werror=declaration-after-statement`:

```nix
env.NIX_CFLAGS_COMPILE = "-Wno-error=declaration-after-statement";
```

## nixpkgs-contrib commits

- `1d9e654c2` — initial fix via configureFlags (broken)
- `b4a2b19de` — corrected to use `env.NIX_CFLAGS_COMPILE`

## Cross-debug category

**Non-pattern: GCC 15 + glibc 2.42 compiler bump.** Same class as
cross-debug/14 (ghostscript). Fix belongs upstream in nixpkgs regardless of
pseudo-cross.
