# Plan: Fundamental Fixes for Pseudo-Cross Failure Patterns

## Context

The galaxybook4-pro360 pseudo-cross build (BUILD = yulee/znver5, HOST = x86_64
+ `gcc.arch=meteorlake`) currently relies on ≈21 ad-hoc nixpkgs-patch leaf
fixes plus large package-side workarounds. These were documented across
cross-debug/57–104 and synthesized into Patterns A–G in
`/home/r0k0r/flakes/nixos/cross-debug/00-pseudo-cross-fundamental-patterns.md`.

The verifying exploration of pinned upstream nixpkgs
(`/nix/store/77dbgds155bbz3vd3qywq1sii07i5ljs-source/`) confirmed:

- **No `isPseudoCross` flag exists** — every per-package fix re-implements
  `stdenv.buildPlatform != stdenv.hostPlatform && configs match` ad-hoc.
- **PR #526112's mechanism is NOT in the current pin** — bintools-wrapper still
  installs prefixed names only (`pkgs/build-support/bintools-wrapper/default.nix`
  lines 257-274).
- **strictDeps gating is centralised** at one `if [[ -z "${strictDeps-}" ]]`
  in `pkgs/stdenv/generic/setup.sh` line 906–921.
- **No `CMAKE_PROGRAM_PATH` infrastructure** exists in the cmake setup hook.
- **No `-march` dedup** in cc-wrapper.sh (only `-march=native` filter).
- **No GCC specs-file machinery** in cc-wrapper.

The single deepest observation: **nixpkgs treats pseudo-cross identically to
real cross, but pseudo-cross does not share the underlying ABI hazards** that
the cross-specific defenses (prefixed-only wrappers, strictDeps env-hook
skipping, separate PKG_CONFIG_PATH, ld.bfd default) exist to prevent. When
`hostPlatform.config == buildPlatform.config`, both machines run the same
ISA and most defenses are net-negative.

The plan is therefore to **introduce a single `stdenv.isPseudoCross` flag** at
the make-derivation level and use it to selectively relax cross defenses in
five centralised locations. This collapses many leaf workarounds into a small
set of targeted nixpkgs-patch changes.

The intended outcome:

1. nixos-rebuild build/switch keeps working on galaxybook4-pro360.
2. ~10–15 of the 21 ad-hoc per-package workarounds can be removed.
3. Future cross-debug entries shrink to genuinely package-specific cases.
4. The remaining fundamental changes are small and well-scoped enough to
   submit upstream (subset of PR #526112 plus 3–4 follow-ups).

---

## Root Cause Hierarchy

All patterns reduce to **four root causes**:

| Root | Patterns | Fundamental fix |
|---|---|---|
| **R1**: cross wrapper hides bare tool names from PATH | A1, A2, G1, 101, 102 | Auto-prepend BUILD cc-wrapper `/bin` to PATH in any cross stdenv |
| **R2**: strictDeps skips HOST setup hooks | G2, G3, G4, E (issue 1) | Run HOST `envBuildHostHooks` when `isPseudoCross` |
| **R3**: HOST-compiled binaries can't execute on BUILD (SIGILL/format error) | B, B2, G5, 103.tex­lua | Per-package: route through `pkgsBuildBuild.<pkg>` (no global fix possible) |
| **R4**: cmake/qmake invent their own discovery paths that don't match nixpkgs convention | E (issue 2), F, C, D, 96, 103.icu | Per-system targeted fixes |

R1 and R2 together account for ≈70% of the patterns and **are addressed by
one shared core change** (`stdenv.isPseudoCross`). R3 fundamentally cannot be
made global because cmake has no portable way to declare "this target also
runs at build time". R4 is heterogeneous.

---

## Tier 1 — Core change: `stdenv.isPseudoCross` and three global consumers

### F1. Define `stdenv.isPseudoCross` in `make-derivation.nix`

**File:** `pkgs/stdenv/generic/make-derivation.nix` line ≈288 (alongside
`canExecuteHostOnBuild`).

```nix
isPseudoCross =
  hostPlatform != buildPlatform
  && hostPlatform.config == buildPlatform.config;
```

Expose via the existing stdenv attrset mechanism so derivations and setup
hooks can read it as `stdenv.isPseudoCross` (Nix side) and as an env var
`NIX_IS_PSEUDO_CROSS=1` (shell side) for setup.sh consumers.

**Justification:** Single source of truth; eliminates 21+ instances of
`(stdenv.buildPlatform != stdenv.hostPlatform)` checks scattered across
nixpkgs-patch.

### F2. setup.sh: auto-prepend BUILD cc-wrapper `/bin` in cross builds

**File:** `pkgs/stdenv/generic/setup.sh` (the PATH-initialisation section
around the `runHook addInputsHook` area).

**Change:** When `buildPlatform != hostPlatform` (true cross OR pseudo-cross),
also prepend `${pkgsBuildBuild.stdenv.cc}/bin` and
`${pkgsBuildBuild.binutils}/bin` to PATH (in addition to `${stdenv.cc}/bin`
which is the HOST cross wrapper).

This is implemented by wiring `pkgsBuildBuild.stdenv.cc` as an implicit
nativeBuildInput in `mkDerivation` rather than hand-editing setup.sh; the
existing `depsBuildBuild` field is the right vehicle.

**Why this is the deep fix for Pattern A:**
- BUILD cc-wrapper installs plain names (`gcc`, `g++`, `cc`, `c++`, …) because
  for it there is no shadowing concern.
- BUILD `gcc` compiles for buildPlatform (znver5, no `-march`) — safe to
  execute on BUILD machine.
- HOST cross wrapper continues to install only prefixed names, so HOST
  compilation still routes through `x86_64-unknown-linux-gnu-gcc` via
  CC/CXX env vars.
- Autoconf-style probes (`AC_PROG_CC`, cmake `find_program(gcc)`, qmake
  `system("g++ --version")`) succeed without per-package workarounds.

**Patterns solved:** A1, A2, G1, 101 (stage-2 PATH pollution becomes moot
since BUILD gcc is intentionally first), and obviates ≈8 instances of manual
`pkgsBuildBuild.stdenv.cc` injection in our nixpkgs-patch.

**Critically:** does NOT install plain names in the HOST cross wrapper
itself (that would cause SIGILL via meteorlake binaries running on BUILD).
This is the key correction to PR #526112's approach for compilers — only
binutils (no codegen) is safe to plain-name from the HOST wrapper.

### F3. bintools-wrapper: plain-name symlinks for HOST wrapper in pseudo-cross

**File:** `pkgs/build-support/bintools-wrapper/default.nix` lines 257–274.

**Change:** Inside the symlink-installation loop, when `isPseudoCross == true`
(threaded in via the wrapper derivation's args), ALSO install plain-name
symlinks for `objdump`, `objcopy`, `nm`, `strip`, `ar`, `ranlib`, `readelf`,
`as`, `addr2line`. ld is the existing PR #526112 case.

```nix
for binary in objdump objcopy ... ; do
  if [ -e $ldPath/${targetPrefix}''${binary}${exeSuffix} ]; then
    ln -s $ldPath/${targetPrefix}''${binary}${exeSuffix} $out/bin/${targetPrefix}''${binary}${exeSuffix}
    # NEW: also install plain name in pseudo-cross
    ${lib.optionalString isPseudoCross
      "ln -s $ldPath/${targetPrefix}''${binary}${exeSuffix} $out/bin/''${binary}${exeSuffix}"}
  fi
done
```

**Patterns solved:** A2 (objdump, nm, strip, ar by plain name).

**Why safe (unlike cc-wrapper):** binutils tools are linkers/inspectors with
no codegen. The same `objdump` binary works equally on znver5 and meteorlake
inputs — there is no analogue of the `-march=meteorlake` codegen hazard.

### F4. setup.sh strictDeps: run HOST `envBuildHostHooks` in pseudo-cross

**File:** `pkgs/stdenv/generic/setup.sh` lines 906–921.

**Change:** Relax the strictDeps gate for pseudo-cross only:

```bash
if [[ -z "${strictDeps-}" || "${NIX_IS_PSEUDO_CROSS-}" == "1" ]]; then
    # … apply envBuildHostHooks et al …
fi
```

**Why safe in pseudo-cross:** Setup hooks like `qmakePathHook` (qt5/qtbase),
the Qt6 cmake env hook (`QT_ADDITIONAL_PACKAGES_PREFIX_PATH`), ECM_DIR,
KF6_HOST_TOOLING just append search-paths to env vars. They cannot inject
incompatible ABI flags because HOST and BUILD configs are identical. The
strictDeps defense exists for real cross where leaking HOST library search
paths into BUILD compilation produces wrong binaries; in pseudo-cross there
is no "wrong binary" produced from a path leak.

**Patterns solved:** G3 (QMAKEPATH), G4 (Qt cmake hooks), G2 (HOST
pkg-config wrapper hook), E issue 1 partially.

**Net effect on nixpkgs-patch:** Removes the need for ≈6 setup-hook
workarounds across qtModule.nix, mk-kde-derivation.nix, quickshell, fcitx5,
breeze-icons, kdoctools.

---

## Tier 2 — Targeted global fixes (each solves one pattern)

### F5. cmake setup hook: populate `CMAKE_PROGRAM_PATH` from nativeBuildInputs

**File:** `pkgs/by-name/cm/cmake/setup-hook.sh`.

Currently the hook populates `NIXPKGS_CMAKE_PREFIX_PATH` only. Add a
parallel function to append each nativeBuildInput's `bin/` to
`CMAKE_PROGRAM_PATH`:

```bash
addCMakeProgramPath() {
    [ -d "$1/bin" ] && addToSearchPath CMAKE_PROGRAM_PATH "$1/bin"
}
addEnvHooks "$hostOffset" addCMakeProgramPath
```

**Patterns solved:** E (cmake's `find_program(X)` now sees nativeBuildInput
binaries without packages needing custom `execute_process(sh -c "which …")`
patches). Removes the cross-debug/94 wayland-scanner-fallback.patch as
generally necessary; remaining cases shrink to genuinely missing tools.

### F6. cc-wrapper: detect duplicate `-march`/`-mcpu`/`-mtune` and prefer last user flag

**File:** `pkgs/build-support/cc-wrapper/cc-wrapper.sh` (extend the
NIX_ENFORCE_NO_NATIVE block at lines 128–141).

**Change:** Before appending `NIX_CFLAGS_COMPILE`, scan user args for
`-march=*`, `-mcpu=*`, `-mtune=*`. If present, suppress nix-supplied
duplicates of the same flag-family.

```bash
user_has_march=0
for p in "${params[@]}"; do
  case "$p" in -march=*) user_has_march=1 ;; esac
done
if [[ $user_has_march == 1 ]]; then
  NIX_CFLAGS_COMPILE_FILTERED=$(printf '%s ' $NIX_CFLAGS_COMPILE | sed 's/-march=[^ ]*//g')
  NIX_CFLAGS_COMPILE=$NIX_CFLAGS_COMPILE_FILTERED
fi
```

**Patterns solved:** F (embree-style ISA dispatch namespaces). Per-object
`-march=sse4.2` would correctly clear ambient `-march=meteorlake` macros.

**Risk:** Some packages might rely on the current "nix flags win" behavior
to enforce a baseline ABI. Mitigate by gating on `isPseudoCross` initially:
the override behavior only activates in pseudo-cross builds. Promote to
unconditional later if it proves benign.

### F7. Linker selection: lld in pseudo-cross

**Where:** Pseudo-cross overlay (currently
`hosts/galaxybook4-pro360/default.nix`). nixpkgs has no central linker
selection knob, so this is implemented as a stdenv override:

```nix
stdenv = pkgs.useMoldLinker pkgs.stdenv;
# or
stdenv = pkgs.llvmPackages.stdenv;
```

applied to the pseudo-cross overlay's package set.

**Patterns solved:** C (ld.bfd visibility errors). lld tolerates hidden
base-class typeinfo, matching native x86_64-linux behavior.

**Why safe in pseudo-cross:** lld can natively link x86_64 binaries
regardless of `-march` (it does not codegen). The BUILD machine's lld is
ABI-compatible with HOST output.

### F8. i686 third cross layer: use native i686 stdenv

**Where:** Pseudo-cross overlay's `pkgsi686Linux` override.

```nix
pkgsi686Linux = (import nixpkgs {
  localSystem = "i686-linux";
  config = baseConfig;  # no pseudo-cross overlay
}).pkgs;
```

**Patterns solved:** D (enable32Bit triple-cross). i686 builds use their
own native stdenv, avoiding the pseudo-cross overlay inheritance.

---

## Tier 3 — Per-package fundamental fixes (cannot be globalized)

These match Pattern R3 (HOST binary can't run on BUILD) and pure ABI fixes.
For each, the fundamental fix lives in the package itself.

### F9. Pattern B / G5: Qt `*Tools_DIR` redirection helper

**File:** Already-patched `pkgs/development/libraries/qt-6/qtModule.nix`
and `pkgs/kde/lib/mk-kde-derivation.nix` (project memory notes 13–14).

**Action:** Keep current per-package overrides. Extract a small helper
`qt6.lib.withBuildBuildTools` so non-Qt consumers (easyeffects, custom
packages) can reuse one helper instead of hand-rolling 6 cmake flags:

```nix
qt6.lib.withBuildBuildTools = pkg: pkg.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or []) ++ qt6.lib.buildBuildToolCmakeFlags;
});
```

### F10. Pattern 102: Go extld via GCC specs file

**File:** New file in `pkgs/development/compilers/go/` plus a tiny stdenv
extension.

**Change:** Generate a per-stdenv specs file that injects `-B`/`-L` for libc
CRT and libgcc into every raw-gcc invocation. Set `GCC_SPECS` (or
`-specs=<path>`) in cross stdenv.

```bash
# In setup.sh cross-init:
export GCC_SPECS=${stdenv.cc}/lib/gcc-cross-pseudo.specs
```

The specs file content:

```
*startfile:
+ -B${stdenv.cc.libc.out}/lib -L${stdenv.cc.libc.out}/lib -L${lib.getLib stdenv.cc.cc}/lib
```

**Patterns solved:** 102 (Go extld), plus any future raw-gcc invocations
that bypass cc-wrapper. This is genuinely more fundamental than the current
per-Go `preBuild LIBRARY_PATH` hack because it works for *any* raw-gcc
caller (LLVM's external linker mode, ad-hoc Makefiles, …) — and it does not
risk colliding with `LIBRARY_PATH` precedence rules in lower-level tooling.

### F11. Pattern 101 GCC bootstrap (already implemented)

Keep current `isPseudoCross` flag in `gcc/common/configure-flags.nix` —
once F1 lands, simplify the local variant to read `stdenv.isPseudoCross`
from the canonical source instead of recomputing.

### F12. Pattern 103.icu76: upstream ICU 76 link fix

**File:** `pkgs/tools/typesetting/tex/texlive/bin.nix` upmendex/bibtexu
sections.

**Action:** Keep current `env.NIX_LDFLAGS = "-licui18n"` workaround.
Submit upstream texlive PR to add `libicui18n` to its configure's
pkg-config requirements. Not cross-specific; an upstream ABI fix.

### F13. Pattern 103.texlua + 104 ttfautohint: cross-platform-guard helper

**File:** `lib/`. Add a small lib helper:

```nix
lib.optionalNative = lib.optionalString (stdenv.buildPlatform == stdenv.hostPlatform);
```

Apply at the texlive `postUnpack`/`postFixup` and ttfautohint `enableGUI`
defaults. Already done in nixpkgs-patch; helper makes future cases tidier.

### F14. Pattern G-overlay: Qt5 chain filter

Per-overlay `lib.filter`-based workaround is already idiomatic. No deeper
fix.

---

## Implementation Order

1. **F1** (`isPseudoCross` flag) — zero-risk addition, no behavior change yet.
2. **F2** (BUILD cc-wrapper in PATH) — enables removing 8 per-package
   `pkgsBuildBuild.stdenv.cc` workarounds. Verify build still succeeds.
3. **F4** (strictDeps relax for pseudo-cross) — enables removing 6 Qt/KDE
   setup-hook workarounds. Verify build still succeeds.
4. **F3** (bintools plain names) — enables removing the embree objdump,
   ispc clang++, OSL clang patches that work around plain-name binutils.
5. **F5** (cmake `CMAKE_PROGRAM_PATH`) — removes wayland-scanner-fallback.patch.
6. **F6** (cc-wrapper `-march` dedup, gated on isPseudoCross) — removes
   embree ISA disable hack.
7. **F7** (lld) — removes webkitgtk visibility workarounds.
8. **F8** (i686 fresh stdenv) — removes libgcrypt doCheck=false workaround.
9. **F10** (GCC specs) — removes Go `preBuild LIBRARY_PATH`.
10. **F9** (`withBuildBuildTools` helper) — tidy, removes duplication.

After each step: full `nixos-rebuild build` on yulee, log any regressions
into cross-debug/.

---

## Verification

End-to-end: each step is validated by a full pseudo-cross rebuild plus a
spot check on three representative packages:

```sh
nixos-rebuild build --flake /home/r0k0r/flakes/nixos#galaxybook4-pro360 \
  --override-input nixpkgs path:/home/r0k0r/nixpkgs-patch
```

Spot packages: **moonlight-qt** (Pattern G end-to-end), **embree** (Pattern
F), **easyeffects** (Patterns B + G4 + G5; currently excluded — re-include
after F4 lands), **blender** (Patterns A/E end-to-end), **gcc** (Pattern
101 still works), **go** (Pattern 102 still works).

Each step in the implementation order should reduce the
`nixpkgs-patch/CHANGES.md` diff by a measurable number of lines —
quantitatively the metric of "deepening" the fixes. Target: nixpkgs-patch
total diff shrinks from current ≈21 patches to ≈8 (genuine R3/R4 cases).

After the full sequence, `nixos-rebuild switch` on galaxybook4-pro360 (still
the immediate next step).

---

## Risks and Mitigations

- **F2 PATH ordering:** if BUILD cc-wrapper's plain `gcc` accidentally
  shadows HOST CC for HOST compilation, miscompilation. **Mitigation:**
  CC/CXX env vars are set to the prefixed names by cross stdenv; build
  systems that respect CC are unaffected. Bare-`gcc` calls in build systems
  that ignore CC are exactly the targets we want to redirect.

- **F4 strictDeps relaxation:** could mask genuine pseudo-cross bugs.
  **Mitigation:** apply ONLY when `NIX_IS_PSEUDO_CROSS=1`; never in real
  cross. Add a build-log note when hooks are relaxed so regressions are
  traceable.

- **F6 cc-wrapper dedup:** may break packages that depend on nix flags
  winning. **Mitigation:** gate on `isPseudoCross` only at first; promote
  to general after a full nixpkgs-build trial.

- **F7 lld:** different RPATH/RUNPATH semantics may surface latent issues.
  **Mitigation:** apply to pseudo-cross overlay only, not upstream.

- **F10 GCC specs file:** new infrastructure with no precedent in nixpkgs.
  **Mitigation:** scope to pseudo-cross stdenv only; document with extreme
  care; CI on a wide package set before propagating.

- **F1 itself is risk-free** — it adds a read-only attr, no behavior
  change without a consumer.

---

## Files To Be Modified

In `/home/r0k0r/nixpkgs-patch/`:

| Path | Change | Tier |
|---|---|---|
| `pkgs/stdenv/generic/make-derivation.nix` | add `isPseudoCross` | F1 |
| `pkgs/stdenv/generic/setup.sh` | strictDeps relax + BUILD cc-wrapper PATH | F2, F4 |
| `pkgs/build-support/bintools-wrapper/default.nix` | plain-name symlinks | F3 |
| `pkgs/by-name/cm/cmake/setup-hook.sh` | `CMAKE_PROGRAM_PATH` | F5 |
| `pkgs/build-support/cc-wrapper/cc-wrapper.sh` | -march dedup | F6 |
| `pkgs/build-support/cc-wrapper/default.nix` | GCC specs file generation | F10 |
| `pkgs/development/compilers/gcc/common/configure-flags.nix` | already patched; simplify to use canonical flag | F11 |
| `pkgs/development/libraries/qt-6/qtModule.nix` | already patched; extract helper | F9 |
| `pkgs/development/compilers/go/1.25.nix`, `1.26.nix` | remove now-redundant LIBRARY_PATH (covered by F10) | F10 |
| `pkgs/tools/typesetting/tex/texlive/bin.nix` | keep ICU/clisp fixes | F12, F13 |
| `pkgs/tools/typesetting/tex/texlive/tlpdb-overrides.nix` | use lib helper | F13 |
| `pkgs/by-name/tt/ttfautohint/package.nix` | use lib helper | F13 |
| `lib/default.nix` (or `lib/strings.nix`) | add `lib.optionalNative` | F13 |

In `/home/r0k0r/flakes/nixos/`:

| Path | Change |
|---|---|
| `hosts/galaxybook4-pro360/default.nix` | lld stdenv override (F7); i686 fresh stdenv (F8); remove ≈10 obsolete overlay entries after F1–F5 land |
| `cross-debug/00-pseudo-cross-fundamental-patterns.md` | add a "Fundamental fix landed" section pointing to F1–F10 once verified |
| `cross-debug/105-{deepfix-results}.md` | new doc capturing what got removed after each F-step |

---

## Resolved Design Decisions

- **F2 scope:** Pseudo-cross only (gated on `isPseudoCross`). Add an inline
  comment in `setup.sh` documenting how to extend to all cross builds
  (drop the `isPseudoCross` gate, keep only the `buildPlatform !=
  hostPlatform` outer check). This keeps the initial change conservative
  while signposting the broader generalization for a follow-up.
- **F4 scope:** Blanket relax — when `isPseudoCross` is true, HOST
  `envBuildHostHooks` run for every package. No per-package opt-in flag.
  This maximizes the reduction in nixpkgs-patch diff.
- **Upstreaming:** Local first, then upstream. Iterate F1–F10 in
  `/home/r0k0r/nixpkgs-patch/` until galaxybook4-pro360 builds clean.
  Each F-step that survives 2+ weeks of building gets drafted into a
  separate upstream PR (F1 alone, F2+F4 together, F3 atop PR #526112,
  etc.).
- **F7 lld scope:** Apply lld to the entire pseudo-cross overlay (not
  just webkitgtk). Uniform linker behavior across HOST output; treats
  lld as the de facto default linker for pseudo-cross.
