# qtbase: -mwaitpkg in native tools causes SIGABRT on AMD build machine

**Package:** `qtbase-6.11.0` (native / pkgsBuildBuild context)
**Commit:** `030dce97b`
**File:** `pkgs/development/libraries/qt-6/modules/qtbase/default.nix`

See also: `cross-debug/40-qtbase-waitpkg-native-tools.md` for root cause detail.

## Symptom

```
Incompatible processor. This Qt build requires the following features:
    waitpkg
FAILED: [code=134] icons/breeze-icons.qrc ...
```

rcc (from `pkgsBuildBuild.qt6.qtbase`) crashes on yulee (AMD Ryzen 9900X) because
`libQt6Core.so` was compiled with `-mwaitpkg`, making `waitpkg` a required CPU
feature in every tool linked against it.

## Fix

Strip `-mwaitpkg` from all generated ninja compile rules in `postConfigure` for
non-cross (native) builds:

```nix
postConfigure = lib.optionalString (!isCrossBuild) ''
  find . -name '*.ninja' | xargs sed -i 's/ -mwaitpkg//g'
'';
```

The HOST qtbase (cross build) keeps `-mwaitpkg` — galaxybook4-pro360 (Meteorlake)
supports it. Only the BUILD-platform qtbase needs the flag removed so native tools
(`rcc`, `qmlimportscanner`, etc.) run safely on AMD builders.
