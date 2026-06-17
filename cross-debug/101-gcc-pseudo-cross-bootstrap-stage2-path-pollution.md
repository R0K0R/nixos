# cross-debug/101: GCC — multi-stage bootstrap fails in pseudo-cross (stage2 PATH pollution)

**Package:** `gcc` (all versions with langFortran or langGo)
**File:** `pkgs/development/compilers/gcc/common/configure-flags.nix`

## Symptom

Building GCC with Fortran or Go support (langFortran=true or langGo=true) fails
during the stage-2 configure phase with C++ compiler checks like:

```
checking whether C++ compiler works... no
configure: error: C++ compiler cannot create executables
```

or similar linker/CRT errors in the stage-2 reconfigure, even though the stage-1
compiler succeeded and the pseudo-cross wrapper is correctly set up.

## Root Cause

GCC's build system performs a **multi-stage bootstrap** by default:
- Stage 1: build a minimal bootstrap compiler with the outer environment's CC
- Stage 2: reconfigure from scratch using the stage-1 compiler, then build the
  real GCC

Stage 2 invokes `./configure` in a **fresh shell** that inherits PATH and
environment from the outer nixpkgs build. In a pseudo-cross build the outer
PATH contains:
- `depsBuildBuild.gcc` — the BUILD-machine's native compiler, providing plain
  `gcc` / `g++` names
- The pseudo-cross cc-wrapper — provides only prefixed names
  (`x86_64-unknown-linux-gnu-gcc`) not plain `gcc`

Stage-2 `./configure` probes `CC` and `CXX` from its environment, which at
that point equals the plain names from `depsBuildBuild.gcc`. This is the BUILD
machine's znver5 compiler, not the meteorlake cross wrapper. The stage-2
compiler then thinks it's targeting znver5 (or the generic x86_64 baseline)
and all subsequent compilations within the GCC build use the wrong flags.

For Fortran and Go specifically the original code avoided skipping bootstrap
(`disableBootstrap'` stayed false) because a full 3-stage bootstrap is needed
for correct code generation in those languages. But in pseudo-cross this leads
to the stage-2 PATH pollution described above.

## Fix

Detect pseudo-cross at configure-flag evaluation time and force single-stage
build:

```nix
# In configure-flags.nix:
isPseudoCross = !hostIsTarget && targetPlatform.config == hostPlatform.config;
disableBootstrap' = disableBootstrap && (!langFortran || isPseudoCross) && (!langGo || isPseudoCross);
```

Original:
```nix
disableBootstrap' = disableBootstrap && !langFortran && !langGo;
```

`isPseudoCross = true` makes both `(!langFortran || isPseudoCross)` and
`(!langGo || isPseudoCross)` true regardless of langFortran/langGo, so
`disableBootstrap' = disableBootstrap`. Bootstrapping is controlled by the
caller's `disableBootstrap` flag alone, without the Fortran/Go exception.

Passing `--disable-bootstrap` forces GCC to use only the outermost `CC`/`CXX`
set by nixpkgs (the pseudo-cross wrapper), entirely avoiding the stage-2
reconfigure and its PATH pollution.

## Why single-stage is acceptable here

The correctness argument for multi-stage bootstrap (better code generation
through a compiler that compiled itself) still applies, but in pseudo-cross
the stage-2 result would use the wrong compiler anyway. A single-stage build
with the properly wrapped cross compiler is more correct than a multi-stage
build whose stage-2 silently uses the wrong toolchain. The ABI of the final
gcc is still set by the pseudo-cross wrapper's `-march=meteorlake` flags.

## Pattern

Variant of Pattern A: `depsBuildBuild.gcc` in PATH provides plain `gcc` names
that shadow the cross wrapper in sub-processes. Unlike the per-package A1 fix
(add `pkgsBuildBuild.stdenv.cc`), this is internal to GCC's own build procedure
and cannot be fixed from the outside. `--disable-bootstrap` is the only viable
option.
