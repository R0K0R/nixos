# 10 — flutter: `which` missing in postInstall; non-writable HOME

## Two separate failures during flutter's postInstall phase

### Failure A: `which` not found

```
ProcessException: Failed to find "which" in the search path
```

`postInstall` runs `flutter bash-completion`, which internally calls `which`
to locate tools. `which` was only in `nativeInstallCheckInputs` (for the
installCheck phase), not available during the postInstall phase itself.

**Fix:** Added `which` to `nativeBuildInputs` (commit `55dc8c500`).

### Failure B: non-writable HOME (`/homeless-shelter`)

```
FileSystemException: Cannot create file, path = '/homeless-shelter/.config/flutter/...'
```

`flutter bash-completion` initializes flutter's config directory at
`$HOME/.config/flutter`. The Nix sandbox sets `HOME=/homeless-shelter` which
is not writable (by design).

In a native build this is cached and skipped; in a cross build the postInstall
runs from scratch (no binary cache hit) and actually needs a writable HOME.

**Fix:** Set `HOME` to a `mktemp` directory only in cross builds, so the native
drv hash is not affected (commit `6d3877949`):

```bash
postInstall = ''
  ${lib.optionalString (stdenv.buildPlatform != stdenv.hostPlatform) ''
    export HOME=$(mktemp -d)
  ''}
  ...flutter bash-completion...
'';
```

## Cross-debug category

**Non-cross package bug** exposed by the cross build (postInstall runs when
there's no binary cache). Both fixes are correct regardless of cross; they just
weren't triggered in native builds because the substituter provided the drv.
