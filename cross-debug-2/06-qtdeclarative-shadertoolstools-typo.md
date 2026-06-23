# qtdeclarative: Qt6ShaderTools vs Qt6ShaderToolsTools cmake dir typo

**Commit:** `7ea458427`
**File:** `pkgs/development/libraries/qt-6/modules/qtdeclarative/default.nix`

See also: `cross-debug/54-qtdeclarative-qt6shadertoolstools-dir-typo.md`

## Symptom

Qt Quick silently disabled; downstream packages fail:

```
Could NOT find Qt6Quick (missing: Qt6Quick_DIR)
```

## Root Cause

`Qt6ShaderTools` and `Qt6ShaderToolsTools` are two different cmake config directories:

- `Qt6ShaderTools/` — library config (links against libQt6ShaderTools)
- `Qt6ShaderToolsTools/` — tools config (declares the `qsb` binary)

`Qt6QuickDependencies.cmake` calls `_qt_internal_find_tool_dependencies` for
`Qt6ShaderToolsTools` to locate `qsb`. Without `qsb`, Qt Quick is silently
treated as not found.

The cmake flag was set to `Qt6ShaderTools` (the library dir). This is a valid
directory so cmake doesn't error — it just silently doesn't find `qsb`.

## Fix

```nix
# Wrong:
"-DQt6ShaderTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderTools"

# Correct:
"-DQt6ShaderToolsTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
```

Also added the missing `Qt6QuickTools_DIR` to the cross flags block (was absent,
causing cross-debug/55 failures in downstream consumers).
