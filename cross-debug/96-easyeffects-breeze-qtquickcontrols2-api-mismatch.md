# 96 — easyeffects: kdePackages.breeze Qt5 style plugin hits qtquickcontrols2 API mismatch

## Package
`easyeffects` (nixpkgs top-level)

## Symptom
Build fails during Qt5 KDE-framework compilation with:

```
error: no matching function for call to
  'QQmlEngine::QQmlEngine(QQmlEngine::ObjectOwnership, QObject*)'
```

The `qtbase` argument accepted in older Qt5 was removed; `qtquickcontrols2`
from an incompatible branch is being compiled against the wrong Qt5 headers.

## Root cause
`kdePackages.breeze` (KDE 6 / Qt6 package) also ships a **Qt5 Breeze style
plugin** for backwards compatibility.  Its build pulls in
`libsForQt5.__internalKF5.kirigami2`, which cascades through the entire KDE 5
framework chain.  Some packages in that chain (`qtquickcontrols2`) have API
incompatibilities with the `libsForQt5.qtbase` available in the overlay.

`easyeffects` lists `kdePackages.breeze` in `buildInputs` for icon theming,
but on a Niri compositor (Wayland, GTK-native) the Qt5 Breeze style plugin is
never used at runtime.

## Fix
Filter `breeze` out of `easyeffects.buildInputs` in the overlay.
`breeze-icons` (the icon set, no Qt5 plugin) remains via other KDE deps.

```nix
easyeffects = prev.easyeffects.overrideAttrs (old: {
  buildInputs = lib.filter (p: (p.pname or "") != "breeze") (old.buildInputs or [ ]);
  # ... (other fixes in subsequent entries)
});
```

## Why this appears only in pseudo-cross
The pseudo-cross overlay uses `isMeteorLakeHost` guard, so the overlay only
fires for the HOST (meteorlake) package set.  In a normal x86_64 build the
same chain builds fine because the Qt5 header versions align.
