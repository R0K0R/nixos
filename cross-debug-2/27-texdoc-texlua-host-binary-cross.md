# 27 — texlive texdoc: texlua (HOST binary) executed on BUILD machine

**Package:** `texdoc-4.1.1-tlpdb-78234`  
**Fix:** `pkgs/tools/typesetting/tex/texlive/tlpdb-overrides.nix`  
**Commit:** `b33bad5d0`

## Symptom

```
/build/.attr-...: line 2: texlua: command not found
exit code 127
```

## Root Cause

`texdoc`'s override in `tlpdb-overrides.nix` has two hooks that invoke
`texlua`:

1. `postUnpack`: builds `Data.tlpdb.lua` by running:
   ```bash
   "${bin.luatex}"/bin/texlua "$out"/scripts/texdoc/texdoc.tlu ...
   ```

2. `postFixup`: generates a zsh completion file:
   ```bash
   texlua "$out"/bin/texdoc --print-completion zsh > "$TMPDIR"/_texdoc
   ```

`bin.luatex` (and `texlua`) is compiled for HOST (with `-march=meteorlake`).
On the BUILD machine (yulee, znver5), the HOST binary triggers SIGILL or
"command not found" because it can't execute.

Previously documented in `cross-debug/103` Fix 2 but the fix was not
yet applied to nixpkgs-contrib.

## Fix

Wrap both hooks with `lib.optionalString (stdenv.buildPlatform == stdenv.hostPlatform)`:

```nix
postUnpack = lib.optionalString (stdenv.buildPlatform == stdenv.hostPlatform) ''
  if [[ -f "$out"/scripts/texdoc/texdoc.tlu ]]; then
    ...runs texlua...
  fi
'';

postFixup = lib.optionalString (stdenv.buildPlatform == stdenv.hostPlatform) ''
  texlua "$out"/bin/texdoc --print-completion zsh > "$TMPDIR"/_texdoc
  installShellCompletion --zsh "$TMPDIR"/_texdoc
'';
```

The skipped operations are non-critical:
- `Data.tlpdb.lua` (used by texdoc for database search) is optional; texdoc
  works without it.
- The zsh completion file is regenerated on the target machine on first use.

## Pattern

Pattern B (HOST binary executed on BUILD). Same class as texlua in
cross-debug/103.
