{
  config,
  lib,
  ...
}:

{
  /*
    Niri asks GTK to drop CSD (`prefer-no-csd`). That does not remove title bars on
    already-running apps — restart Emacs, not only niri. Emacs PGTK can still request
    CSD; `undecorated' is set in $DOOMDIR/init.el for that case.
  */

  programs.niri.settings =
    let
      niriDefaults = import ./niri-default-binds.nix;
      # Remove whole default binds by key name (same strings as in ./niri-default-binds.nix).
      niriBindKeysToRemove = [
        # Example: drop fuzzel if you only use DMS spotlight.
        # "Mod+D"
      ];
      niriBindsBase = lib.removeAttrs niriDefaults niriBindKeysToRemove;
    in
    {
      prefer-no-csd = true;

      /*
        niri-flake’s merged default uses `default-column-width {}`, which makes niri send a (0, H)
        initial configure — documented as confusing some Wayland clients (Kitty can look “fullscreen”
        or maximize oddly). Use an explicit proportion instead of an empty block.
      */
      layout.default-column-width.proportion = 0.5;

      # Stop listing niri’s built-in “important” actions as (not bound) — overlay shows only real binds.
      hotkey-overlay.hide-not-bound = true;

      /*
        PGTK Emacs often negotiates a modest initial width; force a maximized column on open.

        Important: several `matches` entries are OR’d in niri. Do NOT match on `title = "GNU Emacs"`
        — a Kitty window running `emacs -nw` often sets that terminal title, so the rule would
        wrongly maximize Kitty (“fullscreen”). Restrict to GUI Emacs app IDs only.
      */
      window-rules = [
        {
          matches = [
            { app-id = "^emacs$"; }
            { app-id = "^org\\.gnu\\.emacs$"; }
          ];
          open-maximized = true;
        }
      ];

      # niri-flake emits exactly these binds — defaults live in ./niri-default-binds.nix.
      binds = lib.mergeAttrs niriBindsBase (
        with config.lib.niri.actions;
        {
          /* Override same combo as DMS `enableKeybinds` hotkey-overlay title. */
          "Mod+Space" = lib.mkForce {
            action = spawn "dms" "ipc" "spotlight" "toggle";
            hotkey-overlay.title = "Launcher";
          };

          "Mod+Comma" = lib.mkForce {
            action = { consume-window-into-column = [ ]; };
          };

          "Mod+I" = lib.mkForce {
            action = spawn "dms" "ipc" "settings" "toggle";
            hotkey-overlay.title = "Settings";
          };

          "Mod+Return" = {
            action = spawn "kitty";
            hotkey-overlay.title = "Terminal";
          };

          "Mod+w" = {
            action = spawn "firefox";
            hotkey-overlay.title = "Browser";
          };

          # Not Mod+c: niri folds case; Mod+C is center-column in upstream defaults.
          "Mod+e" = {
            action = spawn "emacsclient" "-c";
            hotkey-overlay.title = "Editor";
          };

          "Mod+a" = {
            action = spawn "dms" "ipc" "call" "plugins" "toggle" "aiAssistant";
            hotkey-overlay.title = "AI Assistant";
          };

          # Compositor-level IME toggle: works in all apps including Firefox where
          # GTK3's zwp_input_method_v2 key routing is unreliable. niri intercepts
          # this before any app, so Firefox can never steal it.
          # -s switches IM, -o/-c activates/deactivates fcitx5 processing (state 2/1).
          # Without -o, fcitx5 stays inactive (state 1 = passthrough) even with hangul IM selected.
          "Hangul" = {
            repeat = false;
            hotkey-overlay.hidden = true;
            action = spawn "sh" "-c"
              ''im=$(fcitx5-remote -n); if [ "$im" = hangul ]; then fcitx5-remote -s keyboard-us; fcitx5-remote -c; else fcitx5-remote -s hangul; fcitx5-remote -o; fi'';
          };
          /*
            To hide from overlay but keep working:
              "Mod+X" = { hotkey-overlay.hidden = true; action.spawn = "foo"; };
          */
        }
      );
    };
}
