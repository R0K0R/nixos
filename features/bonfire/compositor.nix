{ config, lib, osConfig, pkgs, ... }:

/*
  Bonfire Space's half of the compositor configuration -- the same seam
  features/dms/compositor.nix uses, and for the same reason: the compositor
  feature must not know which shell is running.

  These are the SHELL binds from upstream's src/wm/hyprland/config/keybinding.lua
  only. Its window-management, focus, workspace and mouse binds are not
  reproduced: features/hyprland already binds all of them, and that file is not
  installed here.

  The chords are DATA-DRIVEN from features/bonfire/keybinds.nix: baked here as the
  kb() defaults and surfaced as `keybind.<action>` settings by hearth.nix, so they
  are editable in the hearth TUI and applied live by the watcher in home.nix.

  mkAfter for the ordering reason documented at the top of
  features/dms/compositor.nix -- `bonfire` sorts before `hyprland` in the
  alphabetical feature glob, so without it this lands above `local mod`.
*/

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "bonfire"; };
  cfg = osConfig.my.bonfire;
  enabled = cfg.enable && inScope;

  compositor = osConfig.my.desktop.compositor;
  mod = osConfig.my.hyprland.modKey;
  bin = name: "${config.home.homeDirectory}/.local/bin/${name}";

  /*
    STORE PATHS for the binds that exec a bare binary. Every other bind here
    runs a wrapped ~/.local/bin script, which carries rofi and friends on its
    own PATH -- but a bind that names the binary directly execs in Hyprland's
    spawn environment, where rofi and swaync-client are installed by nothing
    (the bonfire package wraps them into its scripts and exposes neither).
    That is why flint (a script) always worked while the launcher (bare
    `rofi`) never did.

    With the emoji plugin, because the emoji bind needs it and upstream's
    install.sh puts rofi-emoji on the system; plain pkgs.rofi would make that
    bind silently show an empty mode list.
  */
  rofi = pkgs.rofi.override { plugins = [ pkgs.rofi-emoji ]; };

  # SUPER+N notification-centre toggle, made MUTUALLY EXCLUSIVE with the pyre: opening the panel
  # parks the dock first, because both claim the right-edge slot and the keystone trapezoid shape
  # (the compositor keystones the "swaync-control-center" layer so the panel IS a dock-card shape --
  # see features/hyprland/trapezoid.patch; geometry matched in features/bonfire home.nix). `pyre`
  # is the dock's PATH wrapper (features/pyre); the guard makes this a plain toggle on a host with
  # no dock. The reverse direction (showing the dock closes the panel) is in pyre's dock.sh.
  notifToggle = pkgs.writeShellScript "flare-toggle" ''
    export PATH=${lib.makeBinPath [ pkgs.swaynotificationcenter pkgs.coreutils ]}''${PATH:+:$PATH}
    command -v pyre >/dev/null 2>&1 && pyre hide >/dev/null 2>&1 || true
    exec swaync-client -t -sw
  '';

  # Toggle a rofi surface: a second press closes it instead of erroring "Rofi
  # already running". Both the drun launcher (SUPER+Space) and flint
  # (SUPER+Tab, itself `rofi -show` with custom modes) are rofi, so one check
  # serves both -- pass the launch command as arguments. pgrep/pkill cover both
  # the bare `rofi` comm and the `.rofi-wrapped` name the plugin override may
  # produce.
  rofiToggle = pkgs.writeShellScript "rofi-toggle" ''
    if ${pkgs.procps}/bin/pgrep -x rofi >/dev/null 2>&1 \
      || ${pkgs.procps}/bin/pgrep -x .rofi-wrapped >/dev/null 2>&1; then
      ${pkgs.procps}/bin/pkill -x rofi 2>/dev/null || true
      ${pkgs.procps}/bin/pkill -x .rofi-wrapped 2>/dev/null || true
    else
      exec "$@"
    fi
  '';

  # Panic gesture (SUPER+SHIFT+Escape): lock the screen INSTANTLY, then SIGKILL
  # every app window behind the lock. Lock first (setsid -f so it outlives this
  # script) so the screen is covered before anything else happens; then kill --
  # panic means the windows go NOW, no graceful close / save prompts. hyprlock
  # and waybar are layer surfaces, not clients, so `hyprctl clients` never lists
  # them and they survive. PIDs 0/-1 (xwayland-internal) are filtered out.
  panic = pkgs.writeShellScript "panic-mode" ''
    ${pkgs.util-linux}/bin/setsid -f ${bin "lock.sh"} >/dev/null 2>&1 || true
    pids=$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.[].pid' | ${pkgs.gnugrep}/bin/grep -vxE '0|-1')
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
  '';

  # --- data-driven shell keybinds (features/bonfire/keybinds.nix) ---
  kbData = import ./keybinds.nix;

  # The exec command per action, run in the shell's wrapped env (store paths / ~/.local/bin scripts).
  # Every action in keybinds.nix must have an entry here.
  kbCmd = {
    launcher        = ''${rofiToggle} ${rofi}/bin/rofi -show drun'';
    flint           = ''${rofiToggle} ${bin "flint.sh"}'';
    emoji           = ''${rofi}/bin/rofi -modi emoji -show emoji'';
    clipboard       = bin "clipboard_menu.sh";
    clipboard_wipe  = ''${bin "clipboard_menu.sh"} --wipe'';
    lock            = bin "lock-warm.sh";
    panic           = "${panic}";
    nightlight      = bin "nightlight_toggle.sh";
    wallpaper       = bin "wallpaper_select.sh";
    wallpaper_video = bin "wallpaper_video_select.sh";
    cava            = bin "cava_manager.sh";
    waybar_cycle    = ''${bin "waybar_manager.sh"} --cycle'';
    record          = bin "record.sh";
    screenshot      = bin "screenshot.sh";
    screenshot_full = ''${bin "screenshot.sh"} --fullscreen'';
    dockbar         = ''${bin "dockbar_manager.sh"} --toggle'';
  };

  # Extra hl.bind args (opts) appended verbatim after the dispatcher, per action.
  kbOpts = {
    lock = '', { locked = true }''; # survive the lock screen
  };

  # Baked kb() defaults table (Lua) + the generated, pcall-wrapped hl.bind calls.
  kbDefaultsLua = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (a: s: ''        ["${a}"] = "${s.chord}",'') kbData);
  kbBindsLua = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (a: _: ''      bindkb(kb("${a}"), hl.dsp.exec_cmd("${kbCmd.${a}}")${kbOpts.${a} or ""})'')
    kbData);
in
{
  config = lib.mkIf (enabled && compositor == "hyprland") {
    wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
      -- Shell keybinds: chords are DATA-DRIVEN from features/bonfire/keybinds.nix. kb(action) returns
      -- the chord -- the baked default in __kb below, overridden live by the watcher-written table
      -- (features/bonfire/home.nix rewrites ~/.local/state/bonfire/keybinds.lua on a hearth `keybind.*`
      -- change, then runs `hyprctl reload`). Each hl.bind is pcall-wrapped so a bad chord typed in the
      -- settings UI logs + skips that one bind rather than failing the whole config -> a blank session.
      --
      -- LUA COMMENTS ONLY in here -- this block is inside a Lua string; a Nix /* */ reaches Hyprland
      -- verbatim and the config dies with "unexpected symbol near '/'" at session start.
      local __kb = {
${kbDefaultsLua}
      }
      do
        local ok, t = pcall(dofile, (os.getenv("HOME") or "") .. "/.local/state/bonfire/keybinds.lua")
        if ok and type(t) == "table" then
          for k, v in pairs(t) do if type(v) == "string" then __kb[k] = v end end
        end
      end
      local function kb(a) return __kb[a] or "" end

${kbBindsLua}
      ${lib.optionalString (!osConfig.my.flare.enable) ''pcall(function() hl.bind("${mod} + N", hl.dsp.exec_cmd("${notifToggle}")) end)''}

      -- Glassmorphism for the bar and the launcher, matching what
      -- features/hyprland enables compositor-side. A layer surface has to opt
      -- into blur; only windows get it automatically.
      hl.layer_rule({ match = { namespace = "^(waybar)$" }, blur = true, ignore_alpha = 0.05 })
      -- rofi is launched fullscreen + transparent (the bonfire-fullscreen-blur
      -- override appended to config.rasi in home.nix), so its layer spans the
      -- whole screen and this blur frosts the entire desktop behind the menu --
      -- a real blur, not a dim. NO ignore_alpha here: the backdrop is fully
      -- transparent, and ignore_alpha would EXCLUDE transparent pixels from the
      -- blur, leaving the desktop sharp. The centered box (mainbox) stays opaque.
      -- animation = "fade": without an explicit layer animation, this fullscreen
      -- layer inherits the global "layers" curve (a SLIDE), so on open the whole
      -- transparent-blur layer slides up from the bottom edge and the centered box
      -- rises with it -- it reads as "the menu blinks small/low then snaps to the
      -- middle" (the pseudo-hidpi blink). A fade appears at the final size + centre
      -- with only opacity ramping: no slide, no scale, no blink.
      hl.layer_rule({ match = { namespace = "^(rofi)$" }, blur = true, animation = "fade" })
      hl.layer_rule({ match = { namespace = "^(swaync.*)$" }, blur = true, ignore_alpha = 0.05 })
    '';
  };
}
