# 08 — texlive/xindy: clisp in buildInputs instead of nativeBuildInputs

## Symptom

```
configure: error: CLISP is required
```

During the xindy (texlive component) configure phase.

## Root cause

`clisp` is used at BUILD time in two places:
1. Configure phase: `./configure` checks for clisp in PATH
2. Build phase: generates `xindy.mem` from Lisp sources

In a cross/pseudo-cross build, `strictDeps` prevents `buildInputs` from being
added to PATH (they are only for linking). `clisp` was in `buildInputs`, so it
was not visible during configure or build.

## Fix

Moved `clisp` to `nativeBuildInputs` in `pkgs/tools/typesetting/tex/texlive/bin.nix`.

```nix
nativeBuildInputs = [
  pkg-config
  perl
  clisp   # ← moved here from buildInputs
];
```

`nativeBuildInputs` are always in PATH during the build phase, even under
`strictDeps`.

## Cross-debug category

**Pattern G3** (`strictDeps` skips BUILD tools from buildInputs). The fix
belongs in nixpkgs infrastructure (correct input classification); no overlay
or per-package workaround needed.

## nixpkgs-contrib commit

`49ca5ce7e`
