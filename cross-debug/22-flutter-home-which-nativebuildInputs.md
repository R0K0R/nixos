# `flutter-3.41.9-unwrapped`: HOME read-only + `which` not found in postInstall

**Package:** `flutter-x86_64-unknown-linux-gnu-3.41.9-unwrapped`
**File:** `pkgs/development/compilers/flutter/flutter.nix`

## Symptom 1 — exit 255, HOME = /homeless-shelter

`postInstall` runs `$out/bin/flutter bash-completion "$TMPDIR/flutter.bash"`.
Flutter tries to create `~/.config/flutter` but HOME is `/homeless-shelter`
(the read-only Nix sandbox fake HOME). Exit code 255.

## Root Cause 1

`writableTmpDirAsHomeHook` was in `nativeInstallCheckInputs`, not
`nativeBuildInputs`. When `doInstallCheck = false` (i.e., in cross builds),
`nativeInstallCheckInputs` is excluded from the environment entirely — including
all phases. The `postInstall` phase runs without a writable HOME.

## Symptom 2 — `which` not found

After fixing HOME, flutter's `postInstall` still failed:
```
ProcessException: Failed to find "which" in the search path.
```
Flutter's bash-completion command internally calls `which` to locate tools.

## Root Cause 2

`which` was in `nativeInstallCheckInputs`, not `nativeBuildInputs`. Same
exclusion applies.

## Fix

Move both `writableTmpDirAsHomeHook` and `which` to `nativeBuildInputs`.
Remove them from `nativeInstallCheckInputs` (they're already available from
`nativeBuildInputs`):

```nix
nativeBuildInputs = [
  makeWrapper
  jq
  gitMinimal
  which                    # ← moved here
  installShellFiles
  writableTmpDirAsHomeHook # ← moved here
]
++ lib.optionals stdenv.hostPlatform.isDarwin [ darwin.DarwinTools ];

doInstallCheck = stdenv.buildPlatform == stdenv.hostPlatform;
nativeInstallCheckInputs = lib.optionals stdenv.hostPlatform.isDarwin [ darwin.DarwinTools ];
```
