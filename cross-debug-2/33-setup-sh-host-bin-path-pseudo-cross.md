# 33 — setup.sh: HOST bin/ dirs not in PATH in pseudo-cross

## Symptom

Any build script that uses `which()` or direct PATH lookup to find a HOST
tool (not cmake `find_program`) fails silently or exits 1/255.

Concrete instance: pyside6 `postInstall` runs:
```bash
python setup.py egg_info --build-type=pyside6
```
The outer `setup.py` spawns an inner invocation with `--internal-build-type=pyside6`.
The inner call calls `find_qtpaths()` in `build_scripts/options.py`:
```python
qtpaths = which("qtpaths6")   # → None
qtpaths = which("qtpaths")    # → None
if qtpaths is None:
    sys.exit(-1)              # exit code 255
```
`qtpaths6` lives in `${qtbase}/bin/` (a HOST buildInput), which is NOT in
PATH in pseudo-cross.

## Other affected packages (non-cmake which() callers)

- blender: bare `python3` lookup in configure scripts
- OSL: `Python3_EXECUTABLE` via subprocess which()
- Any package that shells out to a HOST binary by plain name

## Root Cause

`pkgs/stdenv/generic/setup.sh` function `activatePackage` (around line 850):
```bash
if [[ -z "${strictDeps-}" || "$hostOffset" -le -1 ]]; then
    addToSearchPath _PATH "$pkg/bin"
fi
```
HOST buildInputs have `hostOffset = 0`, so with `strictDeps=1` their `bin/`
dirs are not added to `_PATH` (which becomes `PATH`).

F4 relaxed the setup-hook gate (line ~906) so HOST setup hooks run in
pseudo-cross, but deliberately left the PATH gate untouched.

## Fundamental Fix (F4b)

One-line change in `pkgs/stdenv/generic/setup.sh`:
```bash
# before
if [[ -z "${strictDeps-}" || "$hostOffset" -le -1 ]]; then
# after
if [[ -z "${strictDeps-}" || "$hostOffset" -le -1 || "${NIX_IS_PSEUDO_CROSS-}" == "1" ]]; then
    addToSearchPath _PATH "$pkg/bin"
fi
```

## ⚠️ REBUILD COST WARNING

`setup.sh` is part of the bootstrap closure. **Any change to it invalidates
every pseudo-cross derivation** — effectively a full system rebuild (2+ days).

**Do NOT apply this fix mid-session or mid-rebuild.** Schedule it as a
planned start-of-session change when the builder is idle and you can afford
a full rebuild.

## Workaround (per-package, no rebuild cost)

Pass the tool path explicitly in the affected package's `postInstall`:
```nix
# pyside6 postInstall
${python.pythonOnBuildForHost.interpreter} setup.py egg_info \
  --build-type=pyside6 \
  --qtpaths ${python.pkgs.qt6.qtbase}/bin/qtpaths6
```

## See also

- cross-debug-2/31-qtbase6-cross-cxx-stdlib-h-isystem-order.md — F4 (setup hook gate)
- Plan F4 (setup.sh strictDeps relax) — the hook gate half of this fix
