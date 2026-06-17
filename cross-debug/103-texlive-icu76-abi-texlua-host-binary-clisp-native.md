# cross-debug/103: texlive — three cross/ABI fixes (ICU 76+, texlua, clisp)

**Package:** `texlive` (bin.nix, tlpdb-overrides.nix)

Three independent fixes were needed in the texlive package for the pseudo-cross
build to succeed. They are documented together because they all affect the same
package.

---

## Fix 1 — ICU 76+: `-licui18n` not auto-linked for upmendex and bibtexu

**File:** `pkgs/tools/typesetting/tex/texlive/bin.nix`

### Symptom

Link step for `upmendex` and `bibtexu` fails with:

```
undefined reference to 'ucol_openRules_76'         # upmendex
undefined reference to 'ucol_strcollUTF8_76'       # bibtexu
```

### Root Cause

ICU 76 reorganized its symbol placement. `ucol_openRules` (used by upmendex)
and `ucol_strcollUTF8` (used by bibtexu) now live in `libicui18n`. The
configure scripts for both programs only request the `icu-uc` and `icu-io`
pkg-config components, which do not include `libicui18n`. In ICU 75 and earlier
these symbols happened to be in the libraries that WERE requested; ICU 76 moved
them.

This is not cross-specific — it affects any build with ICU 76+. It surfaces in
the nixpkgs-patch because our nixpkgs pin includes ICU 76.

### Fix

```nix
# upmendex
env.NIX_LDFLAGS = "-licui18n";

# bibtexu
env.NIX_LDFLAGS = "-licui18n";
```

Setting `env.NIX_LDFLAGS` injects `-licui18n` into the linker invocation via
the cc-wrapper, supplementing the libraries found by `pkg-config`.

---

## Fix 2 — texlua guard: HOST binary cannot run on BUILD machine

**File:** `pkgs/tools/typesetting/tex/texlive/tlpdb-overrides.nix`

### Symptom

`postUnpack` or `postFixup` of the texdoc package fails with:

```
/nix/store/.../bin/texlua: Illegal instruction (core dumped)
```

or:

```
/nix/store/.../bin/texlua: Exec format error
```

### Root Cause

`postUnpack` builds `Data.tlpdb.lua` by running:
```bash
"${bin.luatex}"/bin/texlua "$out"/scripts/texdoc/texdoc.tlu ...
```

`postFixup` runs `texlua` to generate a zsh completion file.

`bin.luatex` (and `texlua`) is compiled for the HOST platform (meteorlake with
`-march=meteorlake`). In a pseudo-cross build, these hook scripts run on the
BUILD machine (yulee, znver5). znver5 does not support `waitpkg` and other
meteorlake-specific instructions, so the binary crashes with SIGILL.

This is Pattern B: a HOST-compiled binary is executed on the BUILD machine.

### Fix

Wrap both hooks with `lib.optionalString (stdenv.buildPlatform == stdenv.hostPlatform)`:

```nix
postUnpack = lib.optionalString (stdenv.buildPlatform == stdenv.hostPlatform) ''
  # ...runs texlua to build Data.tlpdb.lua...
'';

postFixup = lib.optionalString (stdenv.buildPlatform == stdenv.hostPlatform) ''
  # ...runs texlua to generate zsh completion...
'';
```

The skipped operations are non-critical for the cross build:
- `Data.tlpdb.lua` (used by texdoc for search) is optional; texdoc works without it.
- The zsh completion file is regenerated on each switch on the target machine.

---

## Fix 3 — clisp must be in nativeBuildInputs for xindy

**File:** `pkgs/tools/typesetting/tex/texlive/bin.nix`

### Symptom

The xindy build fails during configure or build with:

```
bash: clisp: command not found
```

or the `postPatch` `substituteInPlace` produces an incorrect empty path:

```nix
"our $clisp = '/nix/store/EMPTY';"
```

because `$(type -P clisp)` returned nothing.

### Root Cause

`xindy` uses `clisp` as a Lisp interpreter at both configure and build time:
- `postPatch` calls `$(type -P clisp)` to hardcode the clisp path in the
  generated `xindy` script
- The configure phase probes for clisp
- The build phase runs clisp to compile Lisp modules

In a cross build, `buildInputs` packages are not added to PATH. clisp must run
on the BUILD machine during the build phase, so it belongs in `nativeBuildInputs`.

This is Pattern E: a build-time tool needed in PATH, placed in `buildInputs`
instead of `nativeBuildInputs`.

### Fix

```nix
nativeBuildInputs = [
  pkg-config
  perl
  clisp  # configure and build run clisp on the build host
];
```

In a cross build nixpkgs rewrites `clisp` here to `pkgsBuildHost.clisp` (the
BUILD-machine binary). The `buildInputs` entry for clisp is still needed for
the runtime dependency so the generated xindy script can find it at runtime on
the HOST machine.
