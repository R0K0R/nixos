{ lib, ... }:

let
  aiOllamaHost = "yulee";
  /* Must match `ollama list`; adjust if yours differs e.g. `gemma3:27b`. */
  aiOllamaModel = "gemma4-31b";
in
{
  programs.dank-material-shell = {
    enable = true;

    /* Full DMS config lives in ./settings-base.json -- a complete, editable
       snapshot of the runtime config (schema v11), so every knob is a
       placeholder ready to tweak. To adopt changes made in DMS's own settings
       UI: export/copy the live config over settings-base.json and rebuild.
       Deliberate nix-side overrides go in the attrset below (recursiveUpdate:
       attrsets merge deep, lists replace whole).

       Glassmorphism note: schema v11 has no global transparency key -- the
       real knobs are barConfigs[*].transparency/widgetTransparency (0.6/0.65
       in the base) plus popupTransparency/dockTransparency. The frosted look
       itself comes from Hyprland's blur layerrules (wayland/hyprland.nix). */
    settings = lib.recursiveUpdate (lib.importJSON ./settings-base.json) {
      theme = "dark";
      dynamicTheming = true;
    };

    systemd = {
      enable = true;
      restartIfChanged = true;
    };

    enableSystemMonitoring = true;
    enableVPN = true;
    enableDynamicTheming = true;
    enableAudioWavelength = true;
    enableCalendarEvents = true;
    enableClipboardPaste = true;

    niri = {
      # systemd already starts `dms`; spawn-at-startup would run a second copy (duplicate bar).
      enableSpawn = false;
      /*
        Single source of truth for keybinds lives in wayland/niri.nix and wayland/hyprland.nix
        (DMS has no hyprland equivalent of this module, so keeping bindings there is the only
        thing that works for both compositors). DMS's own IPC toggle binds (notifications,
        clipboard, notepad, powermenu, lock, night-mode, audio/brightness, process-list) are
        replicated by hand in those files instead of injected here.
      */
      enableKeybinds = false;
      includes.enable = false;
    };

    plugins = {
      dankKDEConnect.enable = true;
      aiAssistant = {
        enable = true;
        settings = {
          provider = "custom";
          baseUrl = "http://${aiOllamaHost}:8000/v1";
          model = aiOllamaModel;
          saveApiKey = false;
        };
      };
    };
  };
}
