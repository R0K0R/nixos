# cross-debug/104: ttfautohint — GUI build fails in pseudo-cross (enableGUI default)

**Package:** `ttfautohint`
**File:** `pkgs/by-name/tt/ttfautohint/package.nix`

## Symptom

Build fails during the configure or build phase when attempting to build the
optional Qt/GTK graphical frontend:

```
configure: error: cannot find FreeType headers for GUI build
```

or cmake/qmake errors relating to Qt or GTK not found, because the GUI-specific
dependencies are not reliably available in the pseudo-cross toolchain context.

## Root Cause

ttfautohint ships an optional GUI frontend (`ttfautohintGUI`) built with either
Qt or GTK+. The nixpkgs package exposed `enableGUI` as a flag, defaulting to
`true`:

```nix
enableGUI ? true,
```

In a native build this works because Qt/GTK build dependencies are available
and can be linked. In a pseudo-cross build the GUI dependencies either are not
present in the cross-configured package set, or their build system interaction
fails due to the usual cross issues (Pattern G for Qt, or missing pkg-config
paths for GTK).

The GUI is a developer convenience tool for interactively previewing hinting;
it is never installed in the NixOS system profile and is not needed for the
font stack to work.

## Fix

Default `enableGUI` to the native-only case:

```nix
enableGUI ? (stdenv.buildPlatform == stdenv.hostPlatform),
```

In a native build (`buildPlatform == hostPlatform`) `enableGUI` defaults to
`true` as before. In a pseudo-cross build it defaults to `false`, skipping
the GUI configure and build entirely.

Callers that explicitly pass `enableGUI = true` are unaffected; the default
change only avoids the failure in contexts where the GUI is neither built for
nor used.

## Pattern

Standard cross-guard pattern: `lib.optionalString (buildPlatform == hostPlatform)`
or a `? (buildPlatform == hostPlatform)` default is the idiomatic nixpkgs way to
skip host-introspection or graphical features that cannot be built cross.
Similar guards appear in texlive (cross-debug/103 Fix 2) and other packages.
