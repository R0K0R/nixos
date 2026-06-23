# nautilus — blueprint-compiler 0.20.4 SIGSEGV on non-TTY stdout

**Package:** `nautilus`
**Commit:** `574ce0cc0`
**File:** `pkgs/by-name/na/nautilus/package.nix`

## Symptom

```
[10/XX] Generating src/resources/ui/action-bar.ui, ...
FAILED: src/resources/ui/action-bar.ui ...
Subprocess returned status code 139.
```

meson calls `blueprint-compiler batch-compile` to compile `.blp` UI definition
files. The process exits with status 11 (SIGSEGV).

## Root Cause

blueprint-compiler 0.20.4 crashes in GLib type-system cleanup (`g_type_class_unref`)
whenever stdout is not a TTY — which is always the case in the nix sandbox (stdout
is a pipe or file). The XML output is written correctly before the crash; the
nonzero exit code causes meson to mark the step failed.

Confirmed via `strace`: signal 11 arrives after all `write()` syscalls complete,
inside GLib finalizers. Upstream bug, not cross-build-specific.

## Fix

Pre-compile every `.blp → .ui` in `postPatch` (ignoring nonzero exit), verify each
output is non-empty, then patch the meson `custom_target` to `cp` the pre-built
files instead of re-invoking blueprint-compiler:

```nix
postPatch = ''
  for blp in src/resources/ui/*.blp; do
    ui="''${blp%.blp}.ui"
    blueprint-compiler compile "$blp" > "$ui" || true
    [ -s "$ui" ] || { echo "blueprint-compiler produced empty $ui"; exit 1; }
  done
  substituteInPlace src/resources/meson.build \
    --replace-fail \
      "command: [blueprint_cmd, 'batch-compile', '--minify', '@OUTPUT@', '@CURRENT_SOURCE_DIR@', '@INPUT@']," \
      "command: ['sh', '-c', 'mkdir -p \"\$1/ui\" && cp \"\$2/ui/\"*.ui \"\$1/ui/\"', 'sh', '@OUTPUT@', '@CURRENT_SOURCE_DIR@'],"
'';
```

`blueprint-compiler` must appear in `nativeBuildInputs` so it is in PATH during
`postPatch`.
