# niri config.kdl: `niri: command not found` (buildInputs vs nativeBuildInputs)

**Package:** `config.kdl` (from niri-flake home-manager module)
**File:** `flake.nix` in `github:sodiboo/niri-flake` (patched locally at `niri-flake-patch/`)

## Symptom

```
/build/.attr-...: line 1: niri: command not found
```

The `config.kdl` derivation runs `niri validate -c $configPath` to validate
the generated KDL config, then copies it to `$out`. Building fails because
the `niri` binary is not in `PATH`.

## Root Cause

The niri-flake's `validated-config-for` function (in `flake.nix`, line ~237):

```nix
validated-config-for =
  pkgs: package: config:
  pkgs.runCommand "config.kdl"
    {
      inherit config;
      passAsFile = [ "config" ];
      buildInputs = [ package ];   # ← WRONG for strictDeps cross builds
    }
    ''
      niri validate -c $configPath
      cp $configPath $out
    '';
```

`package` is the HOST niri (x86_64-unknown-linux-gnu). With `strictDeps = true`
(set by the cross pkgs' stdenv), `buildInputs` are NOT added to `PATH` — only
`nativeBuildInputs` are. The niri binary therefore can't be found.

In pseudo-cross (same ISA), the HOST niri binary IS executable on the BUILD
machine, so placing it in `nativeBuildInputs` works correctly.

## Fix

Change `buildInputs` → `nativeBuildInputs` in `validated-config-for`.

Applied via a local copy of the niri-flake source at `niri-flake-patch/`:
```
git add niri-flake-patch/
```

And updated the main `flake.nix` to use `path:./niri-flake-patch` instead of
`github:sodiboo/niri-flake`.

Upstream fix: `github:sodiboo/niri-flake` should change `buildInputs` to
`nativeBuildInputs` in `validated-config-for` in `flake.nix`.

**Status: FIXED** (local patch; upstream PR needed)
