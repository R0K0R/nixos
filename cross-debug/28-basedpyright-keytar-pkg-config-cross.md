# `basedpyright-1.39.3`: `pkg-config` not found for `keytar` native addon in cross build

**Package:** `basedpyright-x86_64-unknown-linux-gnu-1.39.3`
**File:** `pkgs/by-name/ba/basedpyright/package.nix`

## Symptom

```
npm error /nix/store/.../bash: line 1: pkg-config: command not found
npm error gyp: Call to 'pkg-config --cflags libsecret-1' returned exit status 127
npm error gyp ERR! configure error
npm error gyp ERR! cwd /build/source/node_modules/keytar
```

`node-gyp` rebuilds `keytar` (a native keychain addon) and calls
`pkg-config --cflags libsecret-1`. Returns exit 127 (command not found).

## Root Cause

`pkg-config` IS in `nativeBuildInputs`. Investigation needed into why the
npm/node-gyp subprocess doesn't find it — possible causes:

1. The cross `pkg-config` wrapper is named `x86_64-unknown-linux-gnu-pkg-config`
   and `pkg-config` unqualified points to a different binary not in PATH for the
   npm subprocess.
2. The `node-gyp` subprocess uses a subprocess shell with a different PATH (e.g.,
   npm overwrites `PATH` or uses `--scripts-prepend-node-path`).
3. The npm hook does not inherit the Nix build environment's `PKG_CONFIG_PATH`
   for the cross `libsecret-dev`.

## Fix

In cross builds, remove `keytar/binding.gyp` before the npm build phase.
Without `binding.gyp`, `node-gyp` has no native addon to compile and skips
the `pkg-config` call entirely. Keytar's credential-storage functionality
is not needed for the Python LSP core.

```nix
preBuild = ''...''
  + lib.optionalString (stdenv.buildPlatform != stdenv.hostPlatform) ''
    rm -f node_modules/keytar/binding.gyp
  '';
```

Applied in `pkgs/by-name/ba/basedpyright/package.nix`.
