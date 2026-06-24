# moonlight-qt / pkg-config-wrapper: HOST library pkgconfig paths missing in pseudo-cross

**Commit:** `594f7e103`
**File:** `pkgs/build-support/pkg-config-wrapper/setup-hook.sh`

## Symptom

```
Project ERROR: openssl development package not found
make: *** [Makefile:50: sub-moonlight-common-c-make_first] Error 3
```

moonlight-qt uses qmake with `PKGCONFIG += openssl` in its `.pro` files.
In pseudo-cross, qmake cannot find HOST openssl via pkg-config.

## Root Cause

### How the HOST pkg-config wrapper populates its search path

The HOST pkg-config wrapper (`x86_64-unknown-linux-gnu-pkg-config`) works in
two stages:

1. **At build env setup time**: `pkgConfigWrapper_addPkgConfigPath` (registered
   via `addEnvHooks`) runs for each package and adds its pkgconfig dir to
   `PKG_CONFIG_PATH` (plain var, role_post="" for HOST packages).

2. **At wrapper invocation time**: the wrapper script sources `add-flags.sh`
   which runs `mangleVarListGeneric` to copy `PKG_CONFIG_PATH` into
   `PKG_CONFIG_PATH_x86_64_unknown_linux_gnu`, then sets:
   ```bash
   PKG_CONFIG_PATH=$PKG_CONFIG_PATH_x86_64_unknown_linux_gnu exec pkg-config "$@"
   ```

So HOST library pkgconfig dirs flow: `PKG_CONFIG_PATH` → (at invocation)
`PKG_CONFIG_PATH_x86_64_unknown_linux_gnu` → pkg-config's search path.

### Why step 1 fails in pseudo-cross

`pkg-config-wrapper/setup-hook.sh` line 9 has:
```bash
[[ -z ${strictDeps-} ]] || (( "$hostOffset" < 0 )) || return 0
```

F4's `_addToEnv` relax calls `pkgConfigWrapper_addPkgConfigPath` for HOST
packages (depHostOffset=0) in pseudo-cross. BUT `$hostOffset` is a different
variable from `$depHostOffset` — `$hostOffset` is unset/empty in `_addToEnv`'s
call context (it's a local in `_activatePkgs` which has already returned).

So `(( "" < 0 ))` evaluates to `(( 0 < 0 ))` = false. With `strictDeps=1`,
the hook returns early and HOST packages' pkgconfig dirs are NEVER added to
`PKG_CONFIG_PATH`. The wrapper invocation has nothing to copy, so
`PKG_CONFIG_PATH_x86_64_unknown_linux_gnu` stays empty.

### Why qmake is affected but cmake usually isn't

cmake's `FindPkgConfig` respects the `PKG_CONFIG` env var (set to
`x86_64-unknown-linux-gnu-pkg-config` by F4 relax). cmake uses the HOST
wrapper. When the HOST wrapper's salt var is empty, pkg-config falls back to
system paths — which in the Nix sandbox are empty.

qmake uses `PKGCONFIG += foo` → calls plain `pkg-config` (the BUILD wrapper)
via PATH, which uses `PKG_CONFIG_PATH_<build_salt>` (also unpopulated for HOST
packages). So both cmake and qmake are affected; cmake gets lucky with packages
that provide their own cmake modules, while qmake doesn't.

## Fix

Add a `NIX_IS_PSEUDO_CROSS` bypass to the strictDeps guard, parallel to
what F4 does in `setup.sh`:

```bash
[[ -z ${strictDeps-} ]] || (( "$hostOffset" < 0 )) || [[ "${NIX_IS_PSEUDO_CROSS-}" == "1" ]] || return 0
```

With this, in pseudo-cross:
- `pkgConfigWrapper_addPkgConfigPath` runs for HOST packages (doesn't return early)
- `getHostRoleEnvHook` → `depHostOffset=0` → `role_post=""`
- HOST packages' pkgconfig dirs are added to `PKG_CONFIG_PATH`
- At wrapper invocation, `add-flags.sh` copies them into `PKG_CONFIG_PATH_x86_64_unknown_linux_gnu`
- Both `x86_64-unknown-linux-gnu-pkg-config` (HOST wrapper) and plain `pkg-config`
  (BUILD wrapper, whose `add-flags.sh` also reads `PKG_CONFIG_PATH`) find HOST libraries

BUILD and HOST are ABI-compatible in pseudo-cross (same x86_64 ISA), so mixing
their pkgconfig paths is safe.

## Pattern

This is Pattern E extended: pkg-config path setup hook (not just cmake's
FindPkgConfig) being blocked by the strictDeps guard. The root cause is the
same as F4 (setup.sh `_addToEnv` strictDeps relax) but at the pkg-config
wrapper layer. The F4 fix makes the hooks RUN; this fix makes the hooks DO
SOMETHING useful after they run.

Related: cross-debug-2/16 (wayland-scanner: same HOST pkg-config wrapper
mechanism, but from the other direction — a BUILD tool not found via HOST
pkg-config path).
