{ ... }:

let
  aiOllamaHost = "yulee";
  /* Must match `ollama list`; adjust if yours differs e.g. `gemma3:27b`. */
  aiOllamaModel = "gemma4-31b";
in
{
  programs.dank-material-shell = {
    enable = true;

    /* The full DMS config lives in ./settings.nix as a plain Nix attrset --
       every knob is a visible placeholder; edit there and rebuild. */
    settings = import ./settings.nix;

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
          baseUrl = "http://${aiOllamaHost}:8002/v1";
          model = aiOllamaModel;
          saveApiKey = false;
        };
      };
    };
  };
}
