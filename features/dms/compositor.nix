{ config, lib, pkgs, osConfig, ... }:

/*
  DMS's half of the compositor configuration.

  Every keybind, rule and unit here used to live in features/hyprland or
  features/niri. That made the compositor features unusable without this shell:
  a host running Hyprland with no shell got fifteen binds spawning `dms ipc`
  against nothing, and swapping shells meant editing the compositor.

  It works because home-manager MERGES these options.
  wayland.windowManager.hyprland.extraConfig is types.lines, so every module's
  require("feat.<name>") line (lib/hypr-lua.nix; the Lua itself is
  ./hyprland.lua) is concatenated into the one generated hyprland.lua; niri's
  settings.binds is an attrsOf, so bind attrsets from separate modules combine
  by key.

  ORDER IS NOT OPTIONAL. flake.nix builds the feature list from
  `builtins.readDir ./features`, which is alphabetical, so `dms` sorts BEFORE
  `hyprland`. Definitions of equal priority concatenate in definition order, so
  without mkAfter this file runs before the compositor's own -- calling hl.*
  before hl.config has run. That is a Lua error at session start, which no
  build-time check would have caught.
*/

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "dms"; };

  compositor = osConfig.my.desktop.compositor;
  enabled = osConfig.my.dms.enable && inScope;

  barOrientation = import ./bar-orientation.nix { inherit pkgs; };

  # The same option features/hyprland reads its `mod` from.
  mod = osConfig.my.hyprland.modKey;

  /*
    LID SWITCH, and the reason it belongs to the shell rather than to Hyprland.

    DMS's No Sleep plugin (./plugins/no-sleep) inhibits
    idle:sleep:handle-lid-switch, which blocks logind from taking ANY action on
    lid close -- including its normal screen-off -- leaving the display lit and
    unlocked inside a closed lid for as long as the inhibitor holds. Rather than
    have the plugin manage its own lock/DPMS watcher (a long-running process,
    with all the QML-lifetime pitfalls that hit rotation-lock's respawn), let
    Hyprland handle the lid switch directly: it reads the raw libinput switch
    event itself, independent of logind, via a static keybind that is never
    spawned or torn down by any widget.

    Both scripts gate on whether the plugin's inhibitor is actually held (pgrep
    on its --who= tag, the plugin's only externally-visible marker) so they act
    only while No Sleep is on. Otherwise they no-op and logind's normal suspend
    flow -- already locked via ./session-lock-hooks.nix's sleep.target hook --
    proceeds untouched. That gating is exactly why this is DMS's to own: with no
    DMS there is no inhibitor, and logind needs no help.
  */
  /*
    CLAMSHELL. With No Sleep on, closing the lid just DISABLES the internal
    panel (${osConfig.my.desktop.primaryOutput}) -- always, no external-monitor
    check and no lock. If an external is attached its workspaces move there and
    you keep working (clamshell); if not, the session goes headless until the
    lid reopens, which is fine because the only screen is behind a closed lid
    anyway. No Sleep is a deliberate "keep running" toggle, so not locking here
    is intended; normal lid-close (No Sleep off) still suspends and locks via
    logind + session-lock-hooks.

    Disable/enable go through `hyprctl eval hl.monitor` (the keyword parser is
    gone under configType = "lua"); re-enabling merges disabled=false into the
    output's existing rule, so its mode and scale come back.
  */
  internalOutput = osConfig.my.desktop.primaryOutput;
  lidClose = pkgs.writeShellScript "dms-lid-close" ''
    if ${pkgs.procps}/bin/pgrep -f -- "--who=DMS No Sleep plugin" >/dev/null; then
      hyprctl eval 'hl.monitor({ output = "${internalOutput}", disabled = true })'
    fi
  '';
  lidOpen = pkgs.writeShellScript "dms-lid-open" ''
    if ${pkgs.procps}/bin/pgrep -f -- "--who=DMS No Sleep plugin" >/dev/null; then
      # Re-assert the FULL rule, not just disabled=false: re-enabling merges
      # into the stored rule but does not reliably bring back mode and scale,
      # so restate them (mode/position/scale mirror features/hyprland's own
      # eDP-1 rule). Then DPMS the panel on -- a bare re-enable leaves the
      # backlight off after a real lid close, so the screen stayed black.
      hyprctl eval 'hl.monitor({ output = "${internalOutput}", mode = "preferred", position = "auto", scale = "${osConfig.my.desktop.primaryOutputScale}", disabled = false })'
      hyprctl dispatch 'hl.dsp.dpms({ action = "on" })'
    fi
  '';
in
{
  config = lib.mkMerge [
    # ------------------------------------------------------------------ hyprland
    (lib.mkIf (enabled && compositor == "hyprland") {
      /*
        Pick the right bar once at session start.

        The rotation hook only fires when iio-hyprland reports a CHANGE, so
        logging in already rotated -- or DMS restarting while rotated -- would
        otherwise leave the landscape bar on a 1200px screen, which is the
        overlapping state this whole mechanism exists to avoid.

        After graphical-session.target rather than with it: the bar has to exist
        before it can be revealed or hidden. The script is best-effort anyway,
        and a rotation re-runs it, so losing the race costs nothing permanent.
      */
      systemd.user.services.dms-bar-orientation = {
        Unit = {
          Description = "Select the DMS bar matching the screen orientation";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Install.WantedBy = [ "graphical-session.target" ];
        Service = {
          Type = "oneshot";
          # DMS registers its IPC a moment after the session target is reached.
          # No longer a race for correctness -- the compact bar starts hidden
          # (visible = false in ./settings.nix), so landscape is right from the
          # first frame and this only has to catch the already-rotated case.
          ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
          ExecStart = toString barOrientation;
        };
      };

      # The Hyprland half proper is ./hyprland.lua (lib/hypr-lua.nix).
    })
    (lib.mkIf (enabled && compositor == "hyprland") (import ../../lib/hypr-lua.nix { inherit lib; } {
      name = "dms";
      src = ./hyprland.lua;
      values = { inherit mod; lidClose = "${lidClose}"; lidOpen = "${lidOpen}"; };
    }))

    # ---------------------------------------------------------------------- niri
    /*
      The same binds for niri, and the reason they are hand-written rather than
      injected by DMS's own module: programs.dank-material-shell.niri.enableKeybinds
      is off (see ./home.nix), because it exists only on the niri side and using
      it would mean bindings live in two different places depending on which
      compositor is selected.

      allow-when-locked mirrors hyprland's `locked = true` above, and matters
      most for the transport keys: controlling playback from the buds with the
      lid shut is the point.
    */
    (lib.mkIf (enabled && compositor == "niri") {
      programs.niri.settings.binds =
        let
          dms-ipc = args: {
            action.spawn = [ "dms" "ipc" ] ++ args;
          };
          locked = args: (dms-ipc args) // { allow-when-locked = true; };
        in
        {
          # mkForce: niri-flake's merged defaults already bind these, and the
          # DMS hotkey-overlay title is what should show.
          "Mod+Space" = lib.mkForce {
            action.spawn = [ "dms" "ipc" "spotlight" "toggle" ];
            hotkey-overlay.title = "Launcher";
          };
          "Mod+I" = lib.mkForce {
            action.spawn = [ "dms" "ipc" "settings" "toggle" ];
            hotkey-overlay.title = "Settings";
          };

          # Lowercase, as it was written here before: niri folds case, so
          # "Mod+A" and "Mod+a" are the same key but two different attrset
          # keys -- which would emit the bind twice.
          "Mod+a" = (dms-ipc [ "call" "plugins" "toggle" "aiAssistant" ]) // {
            hotkey-overlay.title = "AI Assistant";
          };
          "Mod+N" = (dms-ipc [ "notifications" "toggle" ]) // {
            hotkey-overlay.title = "Toggle Notification Center";
          };
          "Mod+P" = (dms-ipc [ "notepad" "toggle" ]) // {
            hotkey-overlay.title = "Toggle Notepad";
          };
          "Mod+V" = (dms-ipc [ "clipboard" "toggle" ]) // {
            hotkey-overlay.title = "Toggle Clipboard Manager";
          };
          "Mod+X" = (dms-ipc [ "powermenu" "toggle" ]) // {
            hotkey-overlay.title = "Toggle Power Menu";
          };
          "Mod+M" = (dms-ipc [ "processlist" "toggle" ]) // {
            hotkey-overlay.title = "Toggle Process List";
          };
          "Mod+Alt+N" = (locked [ "night" "toggle" ]) // {
            hotkey-overlay.title = "Toggle Night Mode";
          };
          "Super+Alt+L" = (locked [ "lock" "lock" ]) // {
            hotkey-overlay.title = "Toggle Lock Screen";
          };

          "XF86AudioRaiseVolume" = locked [ "audio" "increment" "3" ];
          "XF86AudioLowerVolume" = locked [ "audio" "decrement" "3" ];
          "XF86AudioMute" = locked [ "audio" "mute" ];
          "XF86AudioMicMute" = locked [ "audio" "micmute" ];

          "XF86AudioPlay" = locked [ "mpris" "playPause" ];
          "XF86AudioPause" = locked [ "mpris" "pause" ];
          "XF86AudioStop" = locked [ "mpris" "stop" ];
          "XF86AudioNext" = locked [ "mpris" "next" ];
          "XF86AudioPrev" = locked [ "mpris" "previous" ];

          "XF86MonBrightnessUp" = locked [ "brightness" "increment" "5" "" ];
          "XF86MonBrightnessDown" = locked [ "brightness" "decrement" "5" "" ];
        };
    })
  ];
}
