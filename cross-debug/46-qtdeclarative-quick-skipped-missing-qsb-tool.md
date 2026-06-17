# 46 — HOST qtdeclarative builds without Qt Quick: missing `qsb` (qtshadertools) native tool

## Symptom cascade

Many packages fail with:
```
Skipping the build as the condition "TARGET Qt::Quick" is not met.
ninja: error: unknown target 'install'
```
Affected: `qtquicktimeline`, `qtlocation`, `qtdatavis3d`, `qtremoteobjects`, `qt3d`,
`qtmultimedia`, `qtquick3d`, `qtgraphs`, KDE packages that depend on Quick, pyside6.

None of these packages fail directly. The root is upstream in qtdeclarative itself.

## Root cause

During the HOST (x86_64-unknown-linux-gnu) qtdeclarative build, Qt's cmake checks
whether the native `qsb` tool from `Qt6ShaderToolsTools` is available. If it
isn't, Qt silently skips all `Quick` and `Quick*` modules:

```
Qt Quick:
  Qt Quick support ....................... no
Note: Qt Quick modules not built due to not finding the qtshadertools 'qsb' tool.
```

`qsb` compiles `.glsl` / `.hlsl` shader files into the binary Qt shader format at
build time. Without it, the Quick scene graph renderer can't be compiled.

This is an instance of the same pattern as [[45-qt-tool-packages-missing-in-pseudo-cross-cmake]]:
native (build-platform) Qt tools are not in the cmake tool search path during a
pseudo-cross HOST package build. `Qt6ShaderToolsTools` (the cmake package containing
`qsb`) lives only in the native (pkgsBuildBuild) qtshadertools output; the HOST
cross-compiled qtshadertools is in the build environment but its cmake dir only
has the HOST library cmake configs, not the native tool executable.

## Evidence

Grep the qtdeclarative build log on the remote builder (yulee) for the clue:

```bash
nix log /nix/store/<qtdeclarative-host.drv> | grep -i "quick\|qsb"
# Qt Quick support ....................... no
# Note: Qt Quick modules not built due to not finding the qtshadertools 'qsb' tool.
```

The local nix daemon does not store remote build logs; always check on the builder.

## Result

HOST `qtdeclarative-x86_64-unknown-linux-gnu-6.11.0` `out` contains ONLY Qml
cmake packages (35 entries: Qt6Qml, Qt6QmlCore, Qt6QmlModels, …).
`Qt6Quick`, `Qt6QuickControls2`, etc. are completely absent.

Compare to native `qtdeclarative-6.11.0` `out` which has 105 cmake packages
including the full Quick stack.

## Fix

Add the native qtshadertools to HOST qtdeclarative's `nativeBuildInputs` and
point cmake directly at the native tool package.

**Important**: Qt modules (qtdeclarative, qtscxml, etc.) live in the `qt6` scope,
NOT in `qt6Packages`. `qt6Packages` is a separate application wrapper scope that
delegates to `pkgsHostTarget.qt6`. Use `prev.qt6.overrideScope` and
`pkgsBuildBuild.qt6.${attr}`:

```nix
qt6 = prev.qt6.overrideScope (_qfinal: qprev: {
  qtdeclarative = qprev.qtdeclarative.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
      final.pkgsBuildBuild.qt6.qtshadertools
    ];
    cmakeFlags = (old.cmakeFlags or []) ++ [
      "-DQt6ShaderToolsTools_DIR=${final.pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
    ];
  });
});
```

## Pitfall: `overrideScope` drops the `.override` attribute

`callPackage` wraps the qt6 scope with `lib.makeOverridable`, adding `.override`
and `.overrideDerivation`. `prev.qt6.overrideScope(...)` returns a plain new scope
from `makeScopeWithSplicing'` that does NOT have `.override`.

This breaks `python-packages.nix`:
```nix
qt6 = pkgs.qt6.override { python3 = self.python; };  # fails: attribute 'override' missing
```

Fix: merge `.override` back from the original after `overrideScope`:
```nix
qt6 = (prev.qt6.overrideScope (_qfinal: qprev: {
  ...
})) // { inherit (prev.qt6) override; };
```

The python3Packages.qt6 scope created by `prev.qt6.override { python3 = ...; }` won't
include our qtdeclarative/qtscxml fixes, but that's acceptable — Python Qt bindings
(PySide6, PyQt6) don't need Qt Quick host builds fixed.

## Overlay ordering matters

This fix must appear BEFORE the `kdePackages.overrideScope` overlay in the
`nixpkgs.overlays` list. kdePackages derives from qt6Packages; if qt6Packages is
patched after kdePackages is constructed, kdePackages will still use the broken
(no-Quick) qtdeclarative.

## Cost

Changing qtdeclarative's drv causes a full rebuild cascade: all packages that
depend (directly or transitively) on qtdeclarative-dev or qtdeclarative-out must
be rebuilt with the new hash. This is a large wave of rebuilds but unavoidable
since all of Qt Quick was previously absent.

## See also

- [[45-qt-tool-packages-missing-in-pseudo-cross-cmake]] — general pattern
- [[44-breeze-icons-qrcalias-host-binary-runs-on-builder]] — related host-tool issue
