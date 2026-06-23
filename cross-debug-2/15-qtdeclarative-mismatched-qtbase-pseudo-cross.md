# qtdeclarative: "detected mismatched Qt dependencies" in pseudo-cross

**Commit:** `194a2c12d`
**File:** `pkgs/development/libraries/qt-6/hooks/qtbase-setup-hook.sh`

## Symptom

```
error: build of '...qtdeclarative-x86_64-unknown-linux-gnu-6.11.0.drv' failed with exit code 1;
Error: detected mismatched Qt dependencies:
    /nix/store/4rdyfpl5ljbh5m66wy32570zk343795l-qtbase-x86_64-unknown-linux-gnu-6.11.0
    /nix/store/ivw4sfdir9pvwf5iscmq94d5sh453vls-qtbase-6.11.0
```

## Root Cause

`qtbase-setup-hook.sh` tracks a global `$__nix_qtbase` variable set on first
invocation.  If the hook is sourced again with a different `@qtbaseOut@` it
raises a fatal error.

In pseudo-cross, F4's strictDeps relax (`NIX_IS_PSEUDO_CROSS=1`) causes
`_addToEnv` in `setup.sh` to run env hooks for **all** packages — both
BUILD-platform and HOST-platform.  The HOST qtdeclarative build has both:

- **HOST qtbase** (meteorlake, in `propagatedBuildInputs`)
- **BUILD qtbase** (znver5, present via BUILD qt packages that end up in
  `nativeBuildInputs` — see below)

Both qtbase setup hooks get sourced, the second invocation sees a different
`$__nix_qtbase`, and the check fires.

### How BUILD qtbase ends up in the build environment

The HOST `qtdeclarative-x86_64-unknown-linux-gnu-6.11.0.drv` has in its
`nativeBuildInputs`:
```
qtshadertools-6.11.0-dev   ← BUILD platform
qtdeclarative-6.11.0-dev   ← BUILD platform (self, cross!)
```

These are present because the isCrossOrPseudo cmakeFlags block in
`qtModule.nix` references `${pkgsBuildBuild.qt6.qtshadertools}` and
`${pkgsBuildBuild.qt6.qtdeclarative}` (to emit Qt6*Tools_DIR flags).
Exactly why the `dev` outputs end up in `nativeBuildInputs` rather than
just `inputDrvs` is a Nix splicing / cross package-set evaluation subtlety
that was not fully traced; the key fact is confirmed from the .drv.

BUILD `qtdeclarative-dev` → `propagated-build-inputs` → BUILD `qtbase-dev`
→ BUILD `qtbase-dev` has setup-hook (same file with `@qtbaseOut@` substituted
to BUILD qtbase out path) → hook sourced → `__nix_qtbase = BUILD_qtbase_out`
→ HOST qtbase hook sourced next → `__nix_qtbase` already set → ERROR.

## The Fix

In pseudo-cross the two qtbase copies are ABI-compatible (same x86_64 ISA,
only different `gcc.arch` optimization flags).  BUILD qtbase is legitimately
needed for cmake tool-dir resolution (rcc/moc/qmlcachegen run on BUILD
machine), while HOST qtbase is the actual link target.  The conflict is a
false positive.

Guard both checks in `qtbase-setup-hook.sh` with
`[[ "${NIX_IS_PSEUDO_CROSS-}" != "1" ]]`:

```bash
# First check (__nix_qtbase conflict):
if [[ "$__nix_qtbase" != "@qtbaseOut@" && "${NIX_IS_PSEUDO_CROSS-}" != "1" ]]; then
    ...fatal error...
fi

# qtToolsHook (qhelpgenerator conflict):
if [[ -n "${qtToolsPathSeen:-}" && "${qttoolsPathSeen:-}" != "$1" && "${NIX_IS_PSEUDO_CROSS-}" != "1" ]]; then
    ...fatal error...
fi
```

This allows the HOST qtbase setup hook to proceed (setting `QMAKE`,
`QT_ADDITIONAL_PACKAGES_PREFIX_PATH`, etc.) while silently ignoring the
BUILD qtbase's hook being sourced again.
