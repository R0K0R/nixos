# libcxx fails to build under the pseudo-cross full-LLVM toolchain

> **RESOLVED 2026-07-29.** Fixed at the stdenv `preHook`, not in the clang
> wrapper. Two claims in the original write-up turned out to be wrong and are
> corrected inline below — see "What actually fixed it". Kept because the
> diagnosis of *how* a stray warning silently swaps libc++'s headers for
> libstdc++'s is the reusable part.

## Symptom

On the `combined-fundamental` fork, building `pkgs.libcxx` (==
`llvmPackages.libcxx`, the pseudo-cross `x86_64-unknown-linux-gnu`
full-LLVM / `clangUseLLVM` runtimes build) fails with a flood of:

```
gcc-15.2.0/include/c++/15.2.0/stdlib.h:38: error: no member named 'abort' in namespace 'std'
runtimes/build/include/c++/v1/stdlib.h:126: error: unknown type name 'ldiv_t'
...
fatal error: too many errors emitted, stopping now
```

Anything whose closure pulls a *from-source* libc++ hits it. It first
surfaced through **Discord** (a prebuilt binary that nonetheless drags its
whole closure — including libcxx — through the fork stdenv). It looks like a
native build failure, which is confusing, because stock nixpkgs builds this
same libcxx fine on Hydra.

## Root cause (confirmed by rebuild + bisection, 2026-07-17)

libc++/libc++abi's CMake probes **every** compiler flag with
`check_cxx_compiler_flag()`, which treats *any* compiler diagnostic matching
its `FAIL_REGEX` (`"argument unused"`, `"unknown .*option"`, `"unrecognized
option"`, …) as the probed flag being **unsupported**. When a stray warning
is emitted on *every* compile, **all** probes fail — the tell is that every
`CXX_SUPPORTS_*_FLAG` reports `Failed`, not just one.

`-nostdinc++` is thereby deemed unsupported and never applied. The nixpkgs
cc-wrapper, seeing no `-nostdinc++` on the command line, then adds
`nix-support/libcxx-cxxflags` — which for this wrapper is
`-cxx-isystem <gcc>/include/c++/15.2.0` (GCC's libstdc++ headers). Pulling
GCC's libstdc++ into the libc++ build is what produces the `abort` /
`ldiv_t` cascade.

**Exactly one** diagnostic trips the `FAIL_REGEX`:

**`-Wno-error=maybe-uninitialized` → "unknown warning option".** This fork
injected the GCC-only `-Wno-error=maybe-uninitialized` into
`NIX_CFLAGS_COMPILE`/`NIX_CXXFLAGS_COMPILE` for *every* build, via the stdenv
`preHook` in `modules/nixos/nix/pkgs-config.nix`. clang has no
`-Wmaybe-uninitialized`, so it emitted "unknown warning option" on every
compile — which matches `FAIL_REGEX "unknown [^\n]*option"`.

### Correction: `-rtlib=compiler-rt` was never part of this

The original write-up claimed a second, co-necessary defect: that
`clangWithLibcAndBasicRt` puts link-only `-rtlib=compiler-rt` in `cc-cflags`,
so every `-c` compile warns "argument unused during compilation", and that this
*also* trips `FAIL_REGEX`. **It does not.** Checked against
`CMakeCheckCompilerFlagCommonPatterns.cmake` (cmake 4.3): none of its 25
`FAIL_REGEX` patterns match "argument unused" — they match *unrecognized* /
*unknown* options, which is a different string.

Confirmed empirically on the current tree, where that warning is still emitted
and nothing is broken:

```
$ nix log …-libcxx-x86_64-unknown-linux-gnu-21.1.8.drv
-- Performing Test CXX_SUPPORTS_NOSTDINCXX_FLAG - Success
clang++: warning: argument unused during compilation: '-rtlib=compiler-rt' …
```

31 `CXX_SUPPORTS_*` probes succeed, 3 fail (genuinely unsupported flags). The
`-rtlib` warning is cosmetic noise. The sibling wrappers carrying
`-Wno-unused-command-line-argument` is a real upstream inconsistency, but it is
a tidiness issue, not this bug.

### Not the cause (earlier wrong guesses, recorded so they aren't retried)

- The wrapper does **not** lack `-nostdlibinc`/`-resource-dir` — it has both
  (its `cc-cflags` is two lines; grepping only the `-rtlib` line hid the
  first). `#include_next` reachability was a *downstream symptom* of
  `-nostdinc++` being dropped, not an independent defect.
- Per-package `NIX_CFLAGS_COMPILE` overrides (via an overlay `overrideAttrs`)
  do **not** work here: in a strictDeps/pseudo-cross build the cc-wrapper
  reads the *role-mangled* `NIX_CFLAGS_COMPILE_<triple>` variables, so a
  plain `NIX_CFLAGS_COMPILE` is silently ignored. The fix has to live in the
  wrapper's baked-in `cc-cflags`.

## What actually fixed it

The waiver is now **gated on the compiler at build time**, in
`modules/nixos/nix/pkgs-config.nix`, so clang stdenvs never see it:

```nix
+ lib.optionalString ((prev.stdenv.hostPlatform.gcc or { }).arch or "" == "meteorlake") ''
    case "''${defaultNativeBuildInputs:-}" in
      *-clang-wrapper-*) ;;
      *)
        export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -Wno-error=maybe-uninitialized"
        export NIX_CXXFLAGS_COMPILE="''${NIX_CXXFLAGS_COMPILE:-} -Wno-error=maybe-uninitialized"
        ;;
    esac
  ''
```

Two things make this work where earlier attempts didn't:

- **Pure-bash `case`, no `$CC` and no `grep`.** The `preHook` runs at the very
  top of `setup.sh`, before `PATH` is populated — an earlier gate shelled out to
  `grep`, got exit 127 for *both* branches, and a leading `!` turned that into an
  unconditional export. `$defaultNativeBuildInputs` is a plain shell variable set
  a few lines above and ends in the cc-wrapper name
  (`…-gcc-wrapper-15.3.0` vs `…-clang-wrapper-21.1.8`), so matching on it needs
  no external process.
- **Eval-time gate on `gcc.arch == "meteorlake"`.** Not correctness, but cache:
  overlays apply to every splice, so without it the string lands in
  `pkgsBuildHost`'s stdenv too and every BUILD-platform derivation diverges from
  upstream. That's ~91% of the toplevel closure.

### Correction: the stdenv fix was affordable after all

The original write-up argued *against* fixing this at the stdenv, on the grounds
that re-hashing every package meant a ~2-day whole-store rebuild, and
recommended the wrapper-level workaround instead. In the event, the stdenv fix
was made and the rebuild came to ~2050 derivations offloaded to victus-15 — a
few hours, not days, because by then the fork's other divergences had been
confined to the stdenvs that need them and cache.nixos.org was serving the
build-platform half of the tree again. **The wrapper flags were never applied**;
`clangWithLibcAndBasicRt` in the fork is untouched at `e4aaab760a30`.

The general lesson is worth keeping: a `stdenv.preHook` edit is expensive, and
its cost depends entirely on how much of the tree is already cache-substitutable.
Re-measure before assuming it's prohibitive.

### Superseded: the Discord workaround

Discord used to be pulled from the unpatched `nixpkgs-upstream` input to
substitute a prebuilt libcxx and avoid the source build. No longer needed —
`modules/nixos/packages/hosts/galaxybook4-pro360.nix` now lists plain `discord`
from the fork. (`upstream.qemu` remains, for unrelated reasons.)
