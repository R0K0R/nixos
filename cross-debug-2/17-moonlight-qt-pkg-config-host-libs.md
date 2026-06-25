# moonlight-qt: BUILD qmake calls bare `pkg-config`, HOST openssl not found

**Commits:** `594f7e103` (pkg-config setup-hook), `1fd90653c` (moonlight-qt preBuild)
**Files:**
- `pkgs/build-support/pkg-config-wrapper/setup-hook.sh`
- `pkgs/by-name/mo/moonlight-qt/package.nix`

## Symptom

```
Project ERROR: openssl development package not found
make: *** [Makefile:50: sub-moonlight-common-c-make_first] Error 3
```

During `buildPhase`, `make` regenerates the Makefile for the
`moonlight-common-c` sub-project by re-running qmake:

```
cd moonlight-common-c/ && ( test -e Makefile || \
  /nix/store/…-qtbase-6.11.0/bin/qmake -o Makefile \
  /build/source/moonlight-common-c/moonlight-common-c.pro ... )
```

The sub-project's `.pro` file uses:
```qmake
CONFIG += link_pkgconfig
PKGCONFIG += openssl
```

## Root Cause (two-layer problem)

### Layer 1: `PKG_CONFIG_PATH` not populated for HOST packages

`pkg-config-wrapper/setup-hook.sh` had a strictDeps guard that prevented HOST
packages' pkgconfig dirs from being added to `PKG_CONFIG_PATH`:

```bash
[[ -z ${strictDeps-} ]] || (( "$hostOffset" < 0 )) || return 0
```

With `strictDeps=1` and `hostOffset` empty (unset in the `_addToEnv` call
context), `(( "" < 0 ))` = false, so the hook returned early. HOST packages
(like `openssl`) were never added to `PKG_CONFIG_PATH`.

**Fix (commit 594f7e103):** Add `NIX_IS_PSEUDO_CROSS` bypass:
```bash
[[ -z ${strictDeps-} ]] || (( "$hostOffset" < 0 )) || [[ "${NIX_IS_PSEUDO_CROSS-}" == "1" ]] || return 0
```

### Layer 2: BUILD qmake calls bare `pkg-config`, not in PATH

Qt's `link_pkgconfig.prf` calls `pkgConfigExecutable()` which defaults to
bare `pkg-config` for non-cross qmake instances. The BUILD qmake
(`qtbase-6.11.0/bin/qmake`, no prefix) is used for sub-project Makefile
generation and is NOT cross-mode.

In pseudo-cross, the only pkg-config binary in PATH comes from the HOST
pkg-config wrapper (`x86_64-unknown-linux-gnu-pkg-config-wrapper`), which
provides only `x86_64-unknown-linux-gnu-pkg-config`. There is NO plain
`pkg-config` binary in PATH.

The BUILD pkg-config wrapper (`pkg-config-wrapper`, no prefix) is NOT in
nativeBuildInputs of moonlight-qt — it's only referenced as the `pkg-config`
Nix function argument, but that resolves differently than what ends up in PATH.

**Fix (commit 1fd90653c):** Add `preBuild` hook to create a plain `pkg-config`
alias pointing at the HOST wrapper:

```nix
preBuild = lib.optionalString stdenv.isPseudoCross ''
  _moonlight_tmpbin=$(mktemp -d)
  _hostPkgConfig=$(command -v "${stdenv.hostPlatform.config}-pkg-config" 2>/dev/null || true)
  if [ -n "$_hostPkgConfig" ]; then
    ln -s "$_hostPkgConfig" "$_moonlight_tmpbin/pkg-config"
    export PATH="$_moonlight_tmpbin:$PATH"
  fi
'';
```

`command -v` at BUILD time finds `x86_64-unknown-linux-gnu-pkg-config` in PATH
(already there from nativeBuildInputs). The symlink makes bare `pkg-config` call
the HOST wrapper, which searches `PKG_CONFIG_PATH` (now populated by Layer 1 fix)
and finds HOST openssl.

## Notes on `${pkg-config}` Nix argument

Using `${pkg-config}/bin/${stdenv.hostPlatform.config}-pkg-config` in the Nix
expression does NOT work: the `pkg-config` function argument resolves to the BUILD
pkg-config wrapper (`pkg-config-wrapper-0.29.2`, no prefix), whose bin dir only
has `pkg-config` (plain), not `x86_64-unknown-linux-gnu-pkg-config`. The symlink
would be dangling. Use `command -v` at build time instead.

## Pattern

Pattern E (binary discovery) + new sub-pattern: BUILD tool (qmake) calling
plain `pkg-config` at buildPhase, not affected by cross-tool PATH setup.

The infrastructure fix would be: pkg-config-wrapper in pseudo-cross should also
provide a plain `pkg-config` symlink → HOST wrapper (analogous to F3's plain
binutils symlinks in bintools-wrapper). Then no per-package preBuild is needed.
Deferred to future infrastructure work.
