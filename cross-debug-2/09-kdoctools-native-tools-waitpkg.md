# kdoctools: docbookl10nhelper/meinproc6/checkXML6 built for HOST, crash on AMD builder

**Commit:** `7ea458427`
**File:** `pkgs/kde/frameworks/kdoctools/default.nix`

See also: `cross-debug/65-kpackage-meinproc6-waitpkg-cross.md`

## Symptom

```
Incompatible processor. This Qt build requires the following features: waitpkg
```

kdoctools cmake phase crashes on yulee (AMD) when POST_BUILD custom commands try
to run `docbookl10nhelper`, `meinproc6`, or `checkXML6`.

## Root Cause

kdoctools compiles these three tools for HOST (meteorlake) during its own build,
then immediately invokes them as cmake `POST_BUILD` custom commands to generate
localization data. HOST binaries require `waitpkg`, which AMD builders lack.

kdoctools CMakeLists.txt has a `CMAKE_CROSSCOMPILING` mode: if
`DOCBOOKL10NHELPER_EXECUTABLE`, `MEINPROC6_EXECUTABLE`, and `CHECKXML6_EXECUTABLE`
are set as cmake cache variables, it uses those imported targets instead of building
and running HOST binaries.

`docbookl10nhelper` is an internal tool not installed by default; it needs
`-DINSTALL_INTERNAL_TOOLS=ON`.

## Fix

Build a BUILD-platform `nativeKdoctools` and pass its binaries via cmake cache vars:

```nix
let
  isCrossOrPseudo =
    (stdenv.isPseudoCross or false) || !stdenv.buildPlatform.canExecute stdenv.hostPlatform;

  nativeKdoctools =
    if isCrossOrPseudo
    then pkgsBuildBuild.kdePackages.kdoctools.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or []) ++ [ "-DINSTALL_INTERNAL_TOOLS=ON" ];
    })
    else null;
in
mkKdeDerivation {
  pname = "kdoctools";

  extraNativeBuildInputs = [ perl perlPackages.URI libxml2 ]
    ++ lib.optional isCrossOrPseudo nativeKdoctools;

  extraCmakeFlags = lib.optionals isCrossOrPseudo [
    "-DDOCBOOKL10NHELPER_EXECUTABLE=${nativeKdoctools}/bin/docbookl10nhelper"
    "-DMEINPROC6_EXECUTABLE=${nativeKdoctools}/bin/meinproc6"
    "-DCHECKXML6_EXECUTABLE=${nativeKdoctools}/bin/checkXML6"
  ];
}
```

`nativeKdoctools` in `extraNativeBuildInputs` ensures the BUILD-platform binaries
are present in the sandbox when cmake verifies the imported targets.
