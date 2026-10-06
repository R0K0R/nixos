{ config, lib, pkgs, osConfig, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "sidedock"; };
  cfg = osConfig.my.sidedock;
  mod = osConfig.my.hyprland.modKey;
  keystone = osConfig.my.hyprland.keystone.enable or false;

  # dock.sh is a plain file (no Nix-escaping headaches); this thin wrapper just puts
  # hyprctl + jq on its PATH. hyprctl comes from the RUNNING compositor's own
  # package so the IPC protocol always matches.
  dock = pkgs.writeShellScript "sidedock" ''
    export PATH=${lib.makeBinPath [ osConfig.programs.hyprland.package pkgs.jq pkgs.coreutils ]}''${PATH:+:$PATH}
    exec ${pkgs.writeShellScript "sidedock-impl" (builtins.readFile ./dock.sh)} "$@"
  '';

  # The dock's own throwaway terminal: keys.terminal spawns a kitty under this
  # class, which the auto-route rule below catches so it opens straight into the pile.
  dockTermClass = "sidedock-term";

  # One auto-route rule per docked app: floating at the dock size, opaque, size-LOCKED
  # (min == max), PINNED (follows the live workspace), tagged 'dock', no initial focus.
  # The size/position literals are only the first frame: dock.sh's `adopt` (fired on
  # window.open below) re-lays the cascade from the live, logical geometry.
  routeRules = lib.concatMapStringsSep "\n      " (c:
    ''hl.window_rule({ match = { class = "^(${c})$" }, float = true, size = "640 928", min_size = "640 928", max_size = "640 928", move = "1266 104", opacity = "1.0 1.0", pin = true, border_size = 0, rounding = 0, no_blur = true, no_shadow = true, tag = "+dock", no_initial_focus = true })''
  ) (cfg.apps ++ [ dockTermClass ]);
in
lib.mkIf (cfg.enable && inScope && osConfig.my.desktop.compositor == "hyprland") {
  wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
      -- Side dock (features/sidedock, from sihooleebd/nixos): light apps live on a
      -- right-edge panel as a CASCADE STACK. Every placement in dock.sh is by
      -- window address, never by focusing, so main-area windows are left alone.
      ${routeRules}
      hl.bind("${mod} + ${cfg.keys.toggle}", hl.dsp.exec_cmd("${dock} toggle"))
      hl.bind("${mod} + ${cfg.keys.dockToggle}", hl.dsp.exec_cmd("${dock} dock-toggle"))
      hl.bind("${mod} + ${cfg.keys.terminal}", hl.dsp.exec_cmd("kitty --class ${dockTermClass}"))
      hl.bind("${mod} + ${cfg.keys.prev}", hl.dsp.exec_cmd("${dock} prev"))
      hl.bind("${mod} + ${cfg.keys.next}", hl.dsp.exec_cmd("${dock} next"))

      do
        -- A rule-applied tag reads as "dock*", a dispatcher one as "dock".
        local function isDockWin(w)
          local hit = false
          pcall(function()
            if w and w.tags then
              for _, t in ipairs(w.tags) do if t == "dock" or t == "dock*" then hit = true; break end end
            end
          end)
          return hit
        end

        -- Keep the cascade in sync as dock windows come and go.
        hl.on("window.open",  function(w) if isDockWin(w) then hl.dispatch(hl.dsp.exec_cmd("${dock} adopt "  .. w.address)) end end)
        hl.on("window.close", function(w) if isDockWin(w) then hl.dispatch(hl.dsp.exec_cmd("${dock} orphan " .. w.address)) end end)

        -- Fullscreening a docked card or dragging one out breaks the cascade, so
        -- the existing SUPER+F and SUPER+drag binds (features/hyprland) are
        -- replaced by guarded versions. Hyprland APPENDS duplicate binds, hence
        -- the unbind first; this fragment is mkAfter, so the originals exist.
        -- Any query error falls through to the normal action.
        local fullscreen = hl.dsp.window.fullscreen({ mode = "fullscreen" })
        hl.unbind("${mod} + F")
        hl.bind("${mod} + F", function()
          if not isDockWin(hl.get_active_window()) then hl.dispatch(fullscreen) end
        end)

        local startDrag = hl.dsp.window.drag()
        hl.unbind("${mod} + mouse:272")
        hl.bind("${mod} + mouse:272", function()
          local overDock = false
          pcall(function()
            local c = hl.get_cursor_pos()
            for _, w in ipairs(hl.get_windows()) do
              if isDockWin(w) and not w.hidden
                 and c.x >= w.at.x and c.x < w.at.x + w.size.x
                 and c.y >= w.at.y and c.y < w.at.y + w.size.y then
                overDock = true
                break
              end
            end
          end)
          if not overDock then hl.dispatch(startDrag) end
        end, { drag = true })
      end

      -- The pile slides as one; give window moves an ease-out without overshoot.
      hl.curve("dockslide", { type = "bezier", points = { { 0.16, 1.0 }, { 0.3, 1.0 } } })
      hl.animation({ leaf = "windowsMove", enabled = true, speed = 5, bezier = "dockslide" })
      ${lib.optionalString keystone ''
      -- Keystone (my.hyprland.keystone, trapezoid.patch): dock windows render as a
      -- perspective trapezoid. Only valid with the patch; stock Hyprland rejects these.
      hl.config({ decoration = { keystone_inset = 0.12, keystone_shrink = 0.08 } })''}
  '';
}
