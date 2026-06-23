# 24 — qtquickcontrols5: qmlcachegen not found in cross build

**Package:** `qtquickcontrols-x86_64-unknown-linux-gnu-5.15.18`  
**Fix:** overlay `qt5.overrideScope` in `hosts/galaxybook4-pro360/default.nix`  
**Commit:** `771a04b`

## Symptom

```
/nix/store/.../bash: line 1: o: command not found
make[2]: *** [Makefile:825: install_qmlcacheinst] Error 3
```

Error 127 (ignored) followed by fatal Error 3 on install step.

## Root Cause

In Qt5's qmake build, `CONFIG += qmlcache` causes a `EXTRA_COMPILERS` entry
that runs `$(QML_CACHEGEN)` to compile `.qml` files to `.qmlc` ahead-of-time
cache files. The variable is populated via:

```makefile
qtPrepareTool(QML_CACHEGEN, qmlcachegen)
```

`qtPrepareTool` searches `QT_HOST_BINS` (= `qtbase.dev/bin`). However
`qmlcachegen` lives in `qtdeclarative.dev/bin`, not `qtbase.dev/bin`. In a
cross build `QT_HOST_BINS` is set to qtbase's bin directory and
`qmlcachegen` is not found → `QML_CACHEGEN` is empty.

The Makefile recipe becomes:
```
 -o output.qmlc source.qml
```
(leading space, then `-o`). Bash interprets `o` as a command → exit 127
(ignored by make because the target is listed as optional). The `.qmlc`
files are never created, but the `INSTALLS` target tries to copy them →
fatal Error 3.

## Fix

Strip `CONFIG += qmlcache` from all `.pro` files in qtquickcontrols via
`postPatch`. The `.qmlc` files are optional ahead-of-time QML bytecache;
their absence only affects startup latency, not correctness.

```nix
qt5 = prev.qt5.overrideScope (_qself: qsuper: {
  ...
  qtquickcontrols = qsuper.qtquickcontrols.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      find . -name '*.pro' -exec sed -i 's/CONFIG += qmlcache//' {} +
    '';
  });
});
```

## Pattern

Pattern B (HOST binary can't run on BUILD) — adjacent. `qmlcachegen` is a
HOST binary that needs to run at build time; it should be in
`nativeBuildInputs` from `pkgsBuildHost` in a proper cross build. The
workaround disables the feature entirely rather than plumbing the binary.
