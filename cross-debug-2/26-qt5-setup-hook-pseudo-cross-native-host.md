# 26 — Qt5 setup hook: native + cross qtbase coexist in pseudo-cross

**Package:** `asymptote-x86_64-unknown-linux-gnu-3.09` (via texlive-combined)  
**Fix:** `pkgs/development/libraries/qt-5/hooks/qtbase-setup-hook.sh`  
**Commit:** `844196671`

## Context

This extends the session-2/23 fix (cross-debug/21). That fix compared Qt
setup hook activations by package **name** (stripping store hash) rather
than full path, to handle the case where BUILD and HOST both produce
`qtbase-x86_64-unknown-linux-gnu-5.15.18-dev` with different hashes.

## New Symptom (asymptote)

```
Error: detected mismatched Qt dependencies:
    /nix/store/4f7581g5...-qtbase-x86_64-unknown-linux-gnu-5.15.18-dev
    /nix/store/5p89p67p...-qtbase-5.15.18-dev
```

Two packages with **different names**:
- `qtbase-x86_64-unknown-linux-gnu-5.15.18-dev` (HOST/cross qtbase from `buildInputs`)
- `qtbase-5.15.18-dev` (native/BUILD qtbase from `wrapQtAppsHook` in `nativeBuildInputs`)

Name-comparison still rejects them because the cross prefix differs.

## Root Cause

`libsForQt5.wrapQtAppsHook` in `nativeBuildInputs` gets spliced to the
BUILD-platform version. Its setup hook fires and sets `__nix_qtbase` to the
BUILD qtbase (`qtbase-5.15.18-dev`). Then the HOST qtbase's setup hook fires
and sees a different name → error.

In pseudo-cross (same ISA), BUILD qtbase and HOST qtbase are ABI-compatible.
There is no genuine incompatibility.

## Fix

Gate the entire consistency check on `NIX_IS_PSEUDO_CROSS`:

```bash
if [[ -n "${__nix_qtbase-}" ]]; then
    if [[ -z "${NIX_IS_PSEUDO_CROSS-}" ]]; then
        # name-comparison check (unchanged for real cross)
        _qt_name_cur="@dev@"; ...
        if [[ "$_qt_name_cur" != "$_qt_name_set" ]]; then
            echo >&2 "Error: detected mismatched Qt dependencies:"
            exit 1
        fi
    fi
    # pseudo-cross: BUILD and HOST qtbase coexist harmlessly — skip
else
    __nix_qtbase="@dev@"
    ...
```

`NIX_IS_PSEUDO_CROSS=1` is set by `make-derivation.nix` when
`stdenv.isPseudoCross` (F1 from the fundamental-fix branch).

## Pattern

G4 (Qt setup hook cross offset mismatch). The fundamental fix (F12 from the
plan) would eliminate the need for both the BUILD and HOST qtbase hooks
firing in the same derivation.
