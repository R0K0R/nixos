{ config, lib, pkgs, osConfig, ... }:

/*
  DMS's half of the compositor configuration.

  Every keybind, rule and unit here used to live in features/hyprland or
  features/niri. That made the compositor features unusable without this shell:
  a host running Hyprland with no shell got fifteen binds spawning `dms ipc`
  against nothing, and swapping shells meant editing the compositor.

  It works because home-manager MERGES these options.
  wayland.windowManager.hyprland.extraConfig is types.lines, so every module
  defining it is concatenated into the one generated hyprland.lua; niri's
  settings.binds is an attrsOf, so bind attrsets from separate modules combine
  by key. Nothing new is generated -- the same file comes out, assembled from
  two places instead of one.

  ORDER IS NOT OPTIONAL. flake.nix builds the feature list from
  `builtins.readDir ./features`, which is alphabetical, so `dms` sorts BEFORE
  `hyprland`. Definitions of equal priority concatenate in definition order, so
  without mkAfter this fragment lands above the compositor's own -- referencing
  `mod` before it exists and calling hl.* before hl.config has run. That is a
  Lua error at session start, which no build-time check would have caught.
*/

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "dms"; };

  compositor = osConfig.my.desktop.compositor;
  enabled = osConfig.my.dms.enable && inScope;

  barOrientation = import ./bar-orientation.nix { inherit pkgs; };

  # Same value features/hyprland writes into `local mod`, read from the option
  # rather than relying on that local having been concatenated above this.
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
  lidClose = pkgs.writeShellScript "dms-lid-close" ''
    if ${pkgs.procps}/bin/pgrep -f -- "--who=DMS No Sleep plugin" >/dev/null; then
      dms ipc call lock lock
      # Lua dispatch form -- legacy "dpms off" no longer parses under
      # configType = "lua", same as the lisgd commands in touch-gestures.
      hyprctl dispatch 'hl.dsp.dpms({ action = "off" })'
    fi
  '';
  lidOpen = pkgs.writeShellScript "dms-lid-open" ''
    if ${pkgs.procps}/bin/pgrep -f -- "--who=DMS No Sleep plugin" >/dev/null; then
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

      wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
        -- DMS's own live colors. Its Hyprland theming writes colors.lua
        -- (general.col.*, group.col.*) as a single hl.config call, which
        -- features/hyprland deliberately leaves unset so there is nothing to
        -- race. layout.lua is NOT required, and must not be: it sets
        -- border_size = 2, and the compositor keeps border_size = 0 because the
        -- touchscreen workspace-swipe activation strip is
        -- (gaps_out + border_size) / screen_height -- see the note beside those
        -- values in features/hyprland/home.nix.
        do
          local xdg = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
          package.path = xdg .. "/hypr/?.lua;" .. xdg .. "/hypr/?/init.lua;" .. package.path
        end
        require("dms.colors")

        -- Glassmorphism for DMS layer surfaces. The compositor enables blur;
        -- a layer surface has to opt in, which is what these do. ignore_alpha
        -- skips near-fully-transparent pixels (the empty regions of the bar
        -- surface) so they don't render as a hazy smear.
        hl.layer_rule({ match = { namespace = "^(dms.*)$" }, no_anim = true, blur = true, ignore_alpha = 0.05 })
        -- Same glass treatment for the OSK (./plugins/osk-toggle): wvkbd's own
        -- --alpha only sets its drawn pixels' transparency, the actual frosted
        -- backdrop still needs Hyprland's blur behind it.
        hl.layer_rule({ match = { namespace = "^(wvkbd)$" }, blur = true, ignore_alpha = 0.05 })

        -- Shell surfaces.
        hl.bind("${mod} + space", hl.dsp.exec_cmd("dms ipc call spotlight toggle"))
        hl.bind("${mod} + I", hl.dsp.exec_cmd("dms ipc call settings toggle"))
        hl.bind("${mod} + A", hl.dsp.exec_cmd("dms ipc call plugins toggle aiAssistant"))
        hl.bind("${mod} + N", hl.dsp.exec_cmd("dms ipc call notifications toggle"))
        hl.bind("${mod} + P", hl.dsp.exec_cmd("dms ipc call notepad toggle"))
        hl.bind("${mod} + V", hl.dsp.exec_cmd("dms ipc call clipboard toggle"))
        hl.bind("${mod} + X", hl.dsp.exec_cmd("dms ipc call powermenu toggle"))
        hl.bind("${mod} + M", hl.dsp.exec_cmd("dms ipc call processlist toggle"))
        hl.bind("${mod} + ALT + N", hl.dsp.exec_cmd("dms ipc call night toggle"))
        hl.bind("${mod} + ALT + L", hl.dsp.exec_cmd("dms ipc call lock lock"))

        -- Hold Super to reveal the workspace numbers. hl.dsp.global routes to
        -- Hyprland's global-shortcuts protocol, which delivers press AND
        -- release -- ./plugins/workspaces' GlobalShortcut turns those straight
        -- into its `peeking` flag. A plain bind fires once and would need a
        -- second release bind plus shared state to reconstruct a hold.
        --
        -- BARE KEY, ignore_mods, transparent -- the shape end-4/dots-hyprland
        -- uses for exactly this gesture, arrived at after the obvious spellings
        -- failed here.
        --
        -- Not "SUPER + Super_L": binding a modifier under its own modmask
        -- cannot match on press, per KeybindManager.cpp
        --
        --   652:  if (... (modmask != k->modmask && !k->ignoreMods) ...) continue;
        --   744:  // key.modmaskAtPressTime is set from currently pressed keys as
        --         // programs see them, but it doesn't yet include the currently
        --         // pressed mod key
        --
        -- When Super_L goes down Hyprland's modmask is still 0 while the bind
        -- demands SUPER (64). ignore_mods alone got press working, but release
        -- was still dropped whenever the hold had been USED for a combo
        -- (Super+1, Super+W), which latched the peek on.
        --
        -- transparent is the missing half: KeybindManager.cpp:867 exempts it
        -- from shadowing alongside `global`, and it stops the bind interfering
        -- with every other Super combo -- so Super keeps working as a modifier
        -- AND both edges get delivered.
        --
        -- Both physical Super keys, since either can start the hold.
        for _, k in ipairs({ "SUPER_L", "SUPER_R" }) do
          hl.bind(k, hl.dsp.global("dms-workspaces:peek"),
                  { ignore_mods = true, transparent = true })
          hl.bind(k, hl.dsp.global("dms-workspaces:peek"),
                  { ignore_mods = true, transparent = true, release = true })
        end

        -- Media/brightness keys: repeating + fires even while locked.
        hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("dms ipc call audio increment 3"), { locked = true, repeating = true })
        hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("dms ipc call audio decrement 3"), { locked = true, repeating = true })
        hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd('dms ipc call brightness increment 5 ""'), { locked = true, repeating = true })
        hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd('dms ipc call brightness decrement 5 ""'), { locked = true, repeating = true })

        -- Mute: locked (fires once already locked) but not repeating.
        hl.bind("XF86AudioMute", hl.dsp.exec_cmd("dms ipc call audio mute"), { locked = true })
        hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("dms ipc call audio micmute"), { locked = true })

        -- Transport keys. Volume and mute were bound; play/next/prev never
        -- were, so anything sending them did nothing at all -- including Galaxy
        -- Buds taps, which arrive over Bluetooth AVRCP as ordinary XF86Audio*
        -- key events, not as some separate headset channel.
        --
        -- locked = true matters more here than for volume: controlling playback
        -- from the buds with the laptop closed is the whole point.
        --
        -- The target need not be a local player. DMS drives whatever MPRIS
        -- players exist, and KDE Connect publishes the phone's and Waydroid's
        -- as org.mpris.MediaPlayer2.kdeconnect.mpris_* on this session bus, so
        -- these keys reach a Waydroid app the same way they reach mpv.
        hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("dms ipc call mpris playPause"), { locked = true })
        hl.bind("XF86AudioPause", hl.dsp.exec_cmd("dms ipc call mpris pause"), { locked = true })
        hl.bind("XF86AudioStop", hl.dsp.exec_cmd("dms ipc call mpris stop"), { locked = true })
        hl.bind("XF86AudioNext", hl.dsp.exec_cmd("dms ipc call mpris next"), { locked = true })
        hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("dms ipc call mpris previous"), { locked = true })

        hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd("${lidClose}"), { locked = true })
        hl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd("${lidOpen}"), { locked = true })
      '';
    })

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
