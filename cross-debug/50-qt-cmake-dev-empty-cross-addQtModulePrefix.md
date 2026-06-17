# 50 — Qt cmake files absent from `dev` output in pseudo-cross; `addQtModulePrefix` misses them

## Symptom

Several HOST Qt modules fail to configure with errors like:

```
CMake Error at .../Qt6Config.cmake:...
  Could not find a configuration file for package "Qt6" that exactly matches
  requested version "6.11.0".
  ...
  The following OPTIONAL packages have not been found:
    * Qt6Quick (required version >= 6.11.0), ...
      Target "Qt6::Quick" ...
```

Affected: `qtquick3d`, `qtdatavis3d`, `qtquicktimeline`, `qtlocation` (Qml),
`qtremoteobjects` (separate native-tool issue, doc 51).

## Root Cause

### Step 1 — cmake file location in cross vs non-cross

In a **non-cross** `qtdeclarative` build:
- `$out/lib/cmake/Qt6Quick/` — cmake config files ✓
- `$dev/lib/cmake/Qt6Quick/` — cmake config files ✓ (multiOutputs copies them)

In a **pseudo-cross** `qtdeclarative` build:
- `$out/lib/cmake/Qt6Quick/` — cmake config files ✓
- `$dev` — completely empty ✗

`qtModule.nix` sets `moveToDev = false`, so the Qt cmake installation logic
controls where cmake files land.  In cross builds the Qt cmake install rules
place cmake files only in `out`.  The exact reason for the non-cross `dev`
having them is unclear (possibly multiOutputs copies them for non-cross but
not cross), but the behaviour is confirmed by direct store-path inspection.

Verified via:
```
$ ls /nix/store/41yb01ksvmwj09jq17w3m0n9gbls6y4v-qtdeclarative-x86_64-unknown-linux-gnu-6.11.0-dev/
# empty
$ ls /nix/store/dd4da6rs537y2q2wdfzf29s2zdc9bg56-qtdeclarative-x86_64-unknown-linux-gnu-6.11.0/lib/cmake/Qt6Quick/
Qt6QuickConfig.cmake  Qt6QuickConfigVersion.cmake  ...
```

### Step 2 — how Qt cmake dirs are found

`nixpkgs/pkgs/development/libraries/qt-6/hooks/qtbase-setup-hook.sh`:
```bash
addQtModulePrefix() {
    addToSearchPath QT_ADDITIONAL_PACKAGES_PREFIX_PATH $1
}
addEnvHooks "$hostOffset" addQtModulePrefix
```

`addEnvHooks "$hostOffset"` fires for each dep with `hostOffset == 0` (i.e.,
BUILD inputs resolved at host = propagatedBuildInputs).  For Qt modules, their
`propagatedBuildInputs` propagate the `dev` output (nixpkgs default).  So
`addQtModulePrefix` is called with the `dev` path of each dep.

In non-cross: `dev` has cmake files → `QT_ADDITIONAL_PACKAGES_PREFIX_PATH`
includes the cmake search path → `find_package(Qt6 COMPONENTS Quick)` works.

In pseudo-cross: `dev` is empty → search path is empty → `Qt6QuickConfig.cmake`
not found → cmake error.

## Fix

### qtModule.nix — record `$out` path in `$dev/nix-support/qt-cmake-prefix`

```nix
postInstall =
  (args.postInstall or "")
  + ''
    mkdir -p "$dev/nix-support"
    echo "$out" > "$dev/nix-support/qt-cmake-prefix"
  '';
```

Every Qt module now writes its `out` store path into the `dev` output's
`nix-support/qt-cmake-prefix` file at install time.  This file is present in
both cross and non-cross builds; in non-cross it's harmless (the `out` path is
added to the search path in addition to the `dev` path that already has cmake
files — Qt cmake files are idempotent to find twice).

### qtbase-setup-hook.sh — read the recorded path

```bash
addQtModulePrefix() {
    addToSearchPath QT_ADDITIONAL_PACKAGES_PREFIX_PATH "$1"
    if [[ -f "$1/nix-support/qt-cmake-prefix" ]]; then
        local _qt_out_path
        _qt_out_path=$(< "$1/nix-support/qt-cmake-prefix")
        [[ -d "$_qt_out_path" ]] && addToSearchPath QT_ADDITIONAL_PACKAGES_PREFIX_PATH "$_qt_out_path"
    fi
}
```

When the `dev` dep is processed, `addQtModulePrefix` now also adds the `out`
path (from the `nix-support/qt-cmake-prefix` file) to the Qt cmake search
path.  For cross builds this provides the path where cmake files actually live.

### Why this is safe

- Non-cross builds: `out` is already in the search path (Qt cmake files in
  `out` are the canonical location; `dev` is a copy).  Adding `out` a second
  time via this mechanism is harmless — `addToSearchPath` deduplicates via
  colon-separated string comparison.
- The `[[ -d "$_qt_out_path" ]]` guard prevents bogus paths.
- `$(<file)` is bash built-in redirection, slightly faster than `cat`.

## Files Changed

- `pkgs/development/libraries/qt-6/qtModule.nix` — add `postInstall` block
- `pkgs/development/libraries/qt-6/hooks/qtbase-setup-hook.sh` — extend `addQtModulePrefix`

## Packages Fixed by This Change

All HOST Qt modules that `propagatedBuildInputs`-depend on `qtdeclarative` or
any other Qt module whose cmake files are only in `out`:

- `qtquick3d` — needs `Qt::Quick`
- `qtdatavis3d` — needs `Qt::Quick`
- `qtquicktimeline` — needs `Qt::Quick`
- `qtlocation` — needs `Qt::Qml`

## See also

- [[48-qt6-scope-overlay-pitfalls]] — overrideScope pitfalls; isMeteorLakeHost guard
- [[46-qtdeclarative-quick-skipped-missing-qsb-tool]] — qtdeclarative Qt Quick native tool fix
- [[51-qtremoteobjects-native-repc-tool]] — qtremoteobjects native tool fix (separate issue)
