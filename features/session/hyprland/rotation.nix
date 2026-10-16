/*
  The rotation half of the Hyprland feature, factored out of home.nix so that
  more than one thing can drive it.

  It used to be private to home.nix because iio-hyprland was the only rotation
  source. features/dms/plugins/vehicle-motion-cues now also produces
  orientation -- it has to own the accelerometer's IIO buffer for its motion
  cues, and only one process can hold that buffer, so it serves rotation from
  the same reader rather than fighting iio-hyprland for the sensor. It emits
  the identical `keyword monitor <out>,transform,N` batch at this same shim,
  so every workaround below keeps applying to both callers and nothing about
  the translation is duplicated on the plugin side.

  Nothing here changed in the move except the wrapping: same shim, same hooks
  script, same flock. See plugins.nix for how the plugin is handed
  `transformHyprctl`.
*/
{ pkgs, lib, rotationHooks }:

let
  /*
    Run every my.hyprland.rotationHooks entry with the new transform.

    A generated script rather than a loop inlined twice: the shim reaches the
    real hyprctl through `exec`, which replaces the process, so hooks have to
    run BEFORE it at both exit paths and there is no "after" to put them in.
    One script means the two call sites cannot drift.

    Best-effort per hook -- a shell that has not started yet, or has no bar to
    swap, must not turn a physical rotation into a screen that never rotates.
  */
  runRotationHooks = pkgs.writeShellScript "hypr-rotation-hooks" (
    ''
      xform="''${1:-0}"
    ''
    + lib.concatMapStrings (h: ''
      ${h} "$xform" >/dev/null 2>&1 || true
    '') rotationHooks
  );

  /*
    iio-hyprland speaks legacy hyprctl -- a four-command keyword batch per
    rotation (monitor transform, touchdevice transform, tablet transform,
    workspace orientation). Under configType = "lua" the keyword parser is
    gone entirely, so this shim (PATH-shadowed for iio-hyprland only,
    below) translates the whole batch into one `hyprctl eval` of the
    equivalent hl.* calls. History worth keeping: the shim originally
    existed for a different bug -- keyword-era Hyprland applied a bare
    "monitor X,transform,N" without recomputing the swapped w/h box, so the
    shim restated the full rule from live monitor state. hl.monitor's
    merge-with-existing-rule application makes that original problem moot.
  */
  hyprctlTransformShim = pkgs.writeShellScriptBin "hyprctl" ''
    real=${pkgs.hyprland}/bin/hyprctl
    if [ "$1" = "--batch" ] && [[ "$2" == *"keyword monitor "*",transform,"* ]]; then
      if [[ "$2" =~ keyword\ monitor\ ([^,]+),transform,([0-9]+) ]]; then
        mon="''${BASH_REMATCH[1]}"
        xform="''${BASH_REMATCH[2]}"
        # Read back by hyprland.lua on every (re)load, so a rebuild's config
        # reload, a logout and a reboot all keep the orientation.
        _state="''${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
        mkdir -p "$_state" 2>/dev/null
        printf '%s\n' "$xform" > "$_state/transform-$mon" 2>/dev/null || true
        if [ "$xform" = "0" ]; then
          # Returning to transform 0 is its own separate bug: even a full
          # monitor rule leaves layer-shell clients stuck at the rotated
          # geometry here, though hyprctl monitors correctly reports
          # transform:0 -- verified live. `reload` reliably forces the
          # resync; under the Lua config it also re-runs the whole script,
          # which resets input:touchdevice/tablet transforms to their
          # config defaults (0) and clears the workspace orientation rule
          # -- exactly the landscape state wanted, and the same net effect
          # the pre-Lua reload had.
          # Back to landscape. Hooks BEFORE exec -- exec replaces this
          # process, so anything after it never runs.
          ${runRotationHooks} "$xform"
          exec "$real" reload
        fi
        # configType = "lua" killed `hyprctl keyword` outright ("keyword
        # can't work with non-legacy parsers. Use eval."), so every part of
        # iio-hyprland's batch must be translated, not just patched. The
        # batch is FOUR commands (main.c, system_fmt):
        #   keyword monitor <out>,transform,N
        #   keyword input:touchdevice:transform N   <- touch mapping
        #   keyword input:tablet:transform N        <- pen mapping
        #   keyword workspace m[ID], layoutopt:orientation:<dir>
        # An earlier version of this shim translated only the monitor line
        # and silently dropped the rest -- display rotated, touch/pen
        # coordinates did not. All four go in one eval now:
        #   - hl.monitor merges into the output's existing rule
        #     (hlMonitor: parser.rule() = *existing), which also obsoletes
        #     the original partial-rule bug this shim was born for
        #   - input transforms are plain config values
        #     (input:touchdevice:transform, input:tablet:transform)
        #   - the orientation keyword is NOT forwarded as-is; it names a
        #     master-layout option this layout ignores, so it is remapped to
        #     scrolling:direction below
        lua="hl.monitor({ output = \"$mon\", transform = $xform }) hl.config({ input = { touchdevice = { transform = $xform }, tablet = { transform = $xform } } })"
        # THE LAYOUT AXIS. iio-hyprland's fourth command is
        #
        #   keyword workspace m[<ID>], layoutopt:orientation:<left|top|right|bottom>
        #
        # which is a MASTER-layout option. general:layout here is "scrolling",
        # and that algorithm never reads `orientation` -- it reads `direction`:
        #
        #   if (WORKSPACERULE->m_layoutopts.contains("direction"))
        #     -- src/layout/algorithm/tiled/scrolling/ScrollingAlgorithm.cpp:1942
        #
        # So the orientation this shim used to forward was translated
        # faithfully and then silently discarded, which is why rotating left
        # windows side by side instead of stacking them.
        #
        # Derived from $xform rather than from iio's orientation word: the
        # transform is unambiguous, and it keeps the mapping readable as
        # "which way is the long axis now".
        #
        #   0 normal    -> right  tape runs across the wide axis
        #   1 90 deg    -> down   long axis is now vertical, so stack
        #   2 180 deg   -> left   horizontal again, reversed
        #   3 270 deg   -> up     vertical again, reversed
        #
        # Set globally rather than per workspace so it applies to workspaces
        # that do not exist yet. Returning to landscape needs no counterpart:
        # the transform-0 branch above execs `reload`, which drops back to the
        # configured default.
        case "$xform" in
          1) _dir=down ;;
          2) _dir=left ;;
          3) _dir=up ;;
          *) _dir=right ;;
        esac
        lua="$lua hl.config({ scrolling = { direction = \"$_dir\" } })"
        # Same reason: hooks before exec, not after.
        ${runRotationHooks} "$xform"
        exec "$real" eval "$lua"
      fi
    fi
    exec "$real" "$@"
  '';

  # Only iio-hyprland's own hyprctl calls go through the shim -- everything
  # else in the session (DMS, terminal, keybinds) keeps using the real one.
  #
  # flock singleton: hard cap of one instance per session, enforced at the
  # wrapper regardless of who spawns it. This is the second half of the
  # 4068-process fork bomb fix (see the hl.on("hyprland.start") comment in
  # extraConfig for the first half): even if some future path re-executes
  # the spawn, the lock makes the duplicate exit instead of joining a
  # rotation -> reload -> respawn feedback loop.
  iioHyprlandWithTransformFix = pkgs.writeShellScriptBin "iio-hyprland" ''
    exec ${pkgs.util-linux}/bin/flock -n "''${XDG_RUNTIME_DIR:-/tmp}/iio-hyprland.lock" \
      ${pkgs.writeShellScript "iio-hyprland-locked" ''
        export PATH="${hyprctlTransformShim}/bin:$PATH"
        exec ${pkgs.iio-hyprland}/bin/iio-hyprland "$@"
      ''} "$@"
  '';
in
{
  inherit runRotationHooks hyprctlTransformShim iioHyprlandWithTransformFix;

  # Absolute path to the shim, for callers that are not PATH-shadowed -- the
  # motion-cues plugin runs it directly by path from QML.
  transformHyprctl = "${hyprctlTransformShim}/bin/hyprctl";
}
