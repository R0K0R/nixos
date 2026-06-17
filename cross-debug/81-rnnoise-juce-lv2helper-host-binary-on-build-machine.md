# cross-debug/81: rnnoise-plugin — juce_lv2_helper HOST binary can't run on BUILD machine

## Problem

After fixing the juceaide compiler issue (cross-debug/80), the build progresses
to ~82% then fails while building the LV2 plugin variant:

```
/nix/store/.../bash: line 1: juce::juce_lv2_helper: command not found
make[2]: *** [.../rnnoise_juce_plugin_stereo_LV2.dir/build.make:202:
  .../rnnoise_stereo.lv2/librnnoise_stereo.so] Error 127
```

## Root cause

JUCE's LV2 support requires a post-processing helper tool, `juce_lv2_helper`,
that generates the LV2 TTL metadata file after the shared library is linked.
cmake adds it as a `add_custom_command(... COMMAND juce::juce_lv2_helper ...)`
that runs during the build phase.

In a pseudo-cross setup this tool is compiled for the **HOST** platform
(meteorlake, -march=meteorlake).  When cmake tries to execute it on the
**BUILD** machine (yulee, AMD znver5), the binary either:

- SIGILLs because znver5 doesn't implement the `waitpkg` instruction set
  extension that -march=meteorlake enables, or
- simply isn't found because cmake generated the cmake target alias
  `juce::juce_lv2_helper` but the path resolution fails.

The `command not found` (exit 127) rather than SIGILL suggests the latter —
cmake emits the cmake target name as the shell command instead of the resolved
binary path when cross-compilation is involved.

This is the same root cause as cross-debug/76 (kdwsdl2cpp-qt6 SIGILL): a
tool compiled for the host that must execute on the build machine.

## Fix

Disable LV2 plugin output entirely with `-DBUILD_LV2_PLUGIN=OFF`.  The JUCE
LV2 helper is only invoked for the LV2 format; disabling it removes the
`juce_lv2_helper` custom command from the cmake graph:

```nix
rnnoise-plugin = prev.rnnoise-plugin.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DBUILD_LV2_PLUGIN=OFF"
  ];
  # Without LV2 the lv2/ subdir is never created; the nixpkgs postInstall
  # loop would fail trying to mv it.  Override to skip lv2 and create an
  # empty lv2 output so the declared Nix output is populated.
  postInstall = ''
    for plugin in ladspa lxvst vst3; do
      mkdir -p ''${!plugin}/lib
      mv $out/lib/$plugin ''${!plugin}/lib/$plugin
      ln -s ''${!plugin}/lib/$plugin $out/lib/$plugin
    done
    mkdir -p $lv2/lib
  '';
  ...
});
```

LV2 is not needed for the kdenlive LADSPA noise-suppression workflow (which
uses the `ladspa` output only).

## Why not fix the helper instead?

Options considered:

1. **Compile juce_lv2_helper for BUILD platform** — JUCE's cmake doesn't
   expose a separate `JUCE_HELPER_TOOLS_PLATFORM` knob.  The helper target
   is wired to `CMAKE_SYSTEM_NAME`/`CMAKE_CROSSCOMPILING` logic inside JUCE
   which doesn't account for pseudo-cross (build == host system, different
   march).

2. **Patch cmake to use pkgsBuildBuild's compiler for the helper** — Would
   require intrusive cmake patches and is more fragile than disabling an
   unneeded format.

3. **Use lld** — Attempted for the earlier webkitgtk_4_1 typeinfo issue
   (cross-debug/78); lld is equally strict about `STV_HIDDEN` symbols and
   the `juce_lv2_helper` problem is a cmake execution issue, not a linker
   issue.

## Files

- `hosts/galaxybook4-pro360/default.nix` — `cmakeFlags` and `postInstall`
  override for `rnnoise-plugin`

## Related

- cross-debug/76 (kdwsdl2cpp SIGILL): HOST binary executed on BUILD machine
- cross-debug/80 (juceaide no compiler): different JUCE tool, same class
- cross-debug/78 (webkitgtk typeinfo): root cause for removing webkitgtk_4_1
  from rnnoise-plugin buildInputs in the first place
