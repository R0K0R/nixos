{ lib, ... }:

let
  dmsDefaultMainBar = import ./bar-spec.nix;
  aiOllamaHost = "yulee";
  /* Must match `ollama list`; adjust if yours differs e.g. `gemma3:27b`. */
  aiOllamaModel = "gemma4-31b";
in
{
  programs.dank-material-shell = {
    enable = true;

    settings = {
      theme = "dark";
      dynamicTheming = true;
      currentThemeName = "monochrome";
      niriLayoutRadiusOverride = 16;
      cursorSettings = {
        size = 12;
        theme = "Adwaita";
        niri = {
          hideWhenTyping = false;
        };
      };
      monoFontFamily = "JetBrainsMono Nerd Font Mono";
      showWorkspaceIndex = true;
      showWorkspacePadding = true;
      showWorkspaceApps = true;
      maxWorkspaceIcons = 1;
      barConfigs = [
        (lib.recursiveUpdate dmsDefaultMainBar {
          rightWidgets = dmsDefaultMainBar.rightWidgets ++ [
            {
              id = "dankKDEConnect";
              enabled = true;
            }
          ];
        })
      ];
      useAutoLocation = true;
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
      /* Merge DMS default niri binds (IPC toggles); `wayland/niri.nix` layers your overrides atop. */
      enableKeybinds = true;
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
