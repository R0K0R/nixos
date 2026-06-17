# 54 — qtdeclarative cross build: Qt6ShaderToolsTools_DIR pointed at wrong cmake dir (Qt6ShaderTools vs Qt6ShaderToolsTools)

## Symptom

All cross Qt packages that depend on `Qt::Quick` fail at cmake configure time:

```
Skipping the build as the condition "TARGET Qt::Quick" is not met.
```

`qtdeclarative` itself builds without error, but inspection reveals that Qt Quick
was **never compiled**:

```
Qt Quick support ....................... no
Note: Qt Quick modules not built due to not finding the qtshadertools 'qsb' tool.
```

and the installed cmake dirs in `qtdeclarative.out/lib/cmake/` contain only 35
entries (no `Qt6Quick*` dirs).  A complete host-platform qtdeclarative build
contains 101 cmake dirs and 54 `Qt6Quick*` dirs.

## Root Cause

`pkgs/development/libraries/qt-6/modules/qtdeclarative/default.nix` line 49 had:

```nix
"-DQt6ShaderToolsTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderTools"
```

`Qt6ShaderTools/` is the **library** cmake config directory.  The **tools** cmake
config (`Qt6ShaderToolsToolsConfig.cmake`) that defines the `qsb` target lives one
directory over in `Qt6ShaderToolsTools/`.  cmake could not find the `qsb`
executable, so Qt disabled the entire Qt Quick subsystem.

### Confirming the directories

```
$ ls /nix/store/kdagmyh…-qtshadertools-6.11.0/lib/cmake/
Qt6ShaderTools/           ← library cmake config (WRONG target for this flag)
Qt6ShaderToolsPrivate/
Qt6ShaderToolsTools/      ← tools cmake config (contains Qt6ShaderToolsToolsConfig.cmake + qsb target)
```

### Why it worked in one older cached drv

The complete qtdeclarative drv `350c132j50w17jw0y61h2pws089szzz5` had the flag set
**twice** — the wrong path unconditionally and the correct path in the cross
conditional block (last-wins in cmake).  At some point the conditional-block entry
was lost, leaving only the wrong unconditional one.

## Fix

In `pkgs/development/libraries/qt-6/modules/qtdeclarative/default.nix`:

```nix
"-DQt6ShaderToolsTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
```

(change `Qt6ShaderTools` → `Qt6ShaderToolsTools`)

Also added `Qt6QuickTools_DIR` to the cross conditional block (build-platform
qtdeclarative's native Quick tool cmake configs, needed for cross compilation of
the host qtdeclarative):

```nix
++ lib.optionals (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) [
  "-DQt6QmlTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
  "-DQt6QuickTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
];
```

## Effect

`qtdeclarative` cross build now compiles Qt Quick modules.  All downstream cross
packages that were failing with "TARGET Qt::Quick is not met" can now configure
successfully.

## Packages Fixed

- `qtquick3d` — needs `Qt::Quick`
- `qtdatavis3d` — needs `Qt::Quick`
- `qtquicktimeline` — needs `Qt::Quick`
- `qtlocation` — needs `Qt::Qml` / `Qt::Quick`
- `qtscxml` — needs `Qt::Qml`
- Any other cross Qt module that `find_package`s Qt Quick components

## Files Changed

- `pkgs/development/libraries/qt-6/modules/qtdeclarative/default.nix` — fix
  `Qt6ShaderToolsTools_DIR` cmake flag; add `Qt6QuickTools_DIR` to cross block

## See also

- [[50-qt-cmake-dev-empty-cross-addQtModulePrefix]] — QT_ADDITIONAL_PACKAGES_PREFIX_PATH populated via qt-cmake-prefix
- [[52-qt-cmake-files-not-in-sandbox-dev]] — cmake files in out not in sandbox
- [[53-qt-cmake-install-libdir-dev]] — CMAKE_INSTALL_LIBDIR approach (ineffective — Qt FORCE-overrides it)
- [[51-qtremoteobjects-native-repc-tool]] — separate native tool fix for qtremoteobjects
