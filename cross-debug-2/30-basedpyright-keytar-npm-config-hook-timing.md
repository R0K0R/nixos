# 30 — basedpyright: keytar native rebuild fails in cross (hook timing)

**Package:** `basedpyright-x86_64-unknown-linux-gnu-1.39.7`  
**Fix:** `pkgs/by-name/ba/basedpyright/package.nix`  
**Commit:** `fc1b35307`

## Symptom

```
npm error gyp ERR! cwd /build/source/node_modules/keytar
npm error gyp ERR! not ok
```

`node-gyp rebuild` fails to build the keytar native addon because the cross
pkg-config wrapper (`x86_64-unknown-linux-gnu-pkg-config`) is not found as
bare `pkg-config` in the node-gyp subprocess.

Previously documented in `cross-debug/28` with a `preBuild` fix that removed
`node_modules/keytar/binding.gyp`. That fix **does not work** in current
nixpkgs — see below.

## Why preBuild is too late

`buildNpmPackage`'s `npmConfigHook` runs as a `postPatchHook`:

```bash
npmConfigHook() {
    npm ci --ignore-scripts        # creates node_modules
    patchShebangs node_modules
    npm rebuild                    # ← keytar fails HERE (inside postPatchHooks)
    patchShebangs node_modules
}
postPatchHooks+=(npmConfigHook)
```

`npm rebuild` fires in `postPatchHooks` (end of patchPhase), BEFORE
`preBuild` (start of buildPhase). A `preBuild` fix that tries to `rm -f
node_modules/keytar/binding.gyp` runs too late.

## Fix

Use `npmRebuildFlags` to pass `--ignore-scripts` to `npm rebuild` in cross
builds, suppressing all install lifecycle scripts (including keytar's native
build):

```nix
npmRebuildFlags = lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
  "--ignore-scripts"
];
```

keytar provides credential-storage integration for OS keychains; the
Python LSP core (basedpyright) functions correctly without it.

## Key Insight

In `buildNpmPackage`, native addon rebuilds happen in **`postPatchHooks`**
via `npmConfigHook`, not in `buildPhase`. Any attempt to disable a native
addon in `preBuild`, `postConfigure`, or similar later hooks misses the
rebuild. The correct knob is `npmRebuildFlags`.
