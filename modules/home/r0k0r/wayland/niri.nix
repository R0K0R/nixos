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
          "Mod+Space" = {
            action = spawn "dms" "ipc" "spotlight" "toggle";
            hotkey-overlay.title = "Launcher";
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
            action = spawn "emacs";
            hotkey-overlay.title = "Editor";
          };

          /*
            To hide from overlay but keep working:
              "Mod+X" = { hotkey-overlay.hidden = true; action.spawn = "foo"; };
          */
        }
      );
    };
}
