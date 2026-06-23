# 25 — texlive: bibtexu + upmendex fail to link (ICU 76 symbol move)

**Package:** `bibtex-x-x86_64-unknown-linux-gnu-3.72` / `texlive-bin-big-x86_64-unknown-linux-gnu-2025`  
**Fix:** `pkgs/tools/typesetting/tex/texlive/bin.nix`  
**Commit:** `cc4078ef3`

## Symptom

```
ld.bfd: bibtexu-bibtex-2.o: undefined reference to symbol 'ucol_strcollUTF8_76'
ld.bfd: /nix/store/.../icu4c.../lib/libicui18n.so.76: error adding symbols: DSO missing from command line
collect2: error: ld returned 1 exit status
```

(upmendex has the same error with `ucol_openRules_76`.)

## Root Cause

ICU 76 reorganized its library layout. `ucol_strcollUTF8` (bibtexu) and
`ucol_openRules` (upmendex) moved from `libicuuc` into `libicui18n`. The
`configure.ac` for both tools requests only `icu-uc` and `icu-io`
pkg-config components, which do not pull in `libicui18n`.

This is **not cross-specific** — it affects any build with ICU 76+.
Previously documented in `cross-debug/103` Fix 1 but the fix was not
yet applied to nixpkgs-contrib.

## Fix

Set `env.NIX_LDFLAGS = "-licui18n"` on both derivations. The cc-wrapper
injects `NIX_LDFLAGS` into every link invocation, supplementing what
`pkg-config` discovered.

```nix
# bibtex8 (builds bibtexu)
env.NIX_LDFLAGS = "-licui18n";

# core-big (builds upmendex)
env.NIX_LDFLAGS = "-licui18n";
```

## Pattern

Non-cross upstream package bug (ICU ABI reorganization). Would surface on
any nixpkgs build with ICU 76.
